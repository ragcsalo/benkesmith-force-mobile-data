package com.benkesmith.forcemobiledata;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.os.Build;
import android.util.Log;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CallbackContext;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;

public class ForceMobileData extends CordovaPlugin {

    private static final String TAG = "ForceMobileData";
    // Tuned down from 5000/5000/1000: the original values gave a robust false-positive
    // guard (see the 2026-09-02 fix) but pushed the worst case for the very first,
    // app-startup checkStatus() call (the one the "Network: checking..." home-screen
    // label waits on) to ~11s. 2 attempts still guards against a one-off transient blip,
    // just with a snappier ceiling (~6.4s worst case).
    private static final int CONNECT_TIMEOUT_MS = 3000;
    private static final int READ_TIMEOUT_MS = 3000;
    private static final int INTERNET_CHECK_ATTEMPTS = 2;
    private static final long INTERNET_CHECK_RETRY_DELAY_MS = 400;
    private static final long RECOVERY_POLL_INTERVAL_MS = 5000;
    // No Wi-Fi (mobile data only), and Android hasn't validated the network yet: one longer probe
    // instead of two 3 s ones - a sleeping mobile radio needs a moment, and the short probes often
    // reported a working mobile connection OFFLINE (the indicator flipped to "no internet").
    private static final int CELLULAR_CONNECT_TIMEOUT_MS = 6000;
    private static final int CELLULAR_READ_TIMEOUT_MS = 6000;

    private ConnectivityManager connectivityManager;
    private ConnectivityManager.NetworkCallback cellularCallback;
    private CallbackContext eventCallbackContext;
    private boolean isForcingCellular = false;
    private android.os.Handler recoveryHandler;
    private Runnable recoveryRunnable;

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        if (connectivityManager == null) {
            connectivityManager = (ConnectivityManager) cordova.getActivity().getSystemService(Context.CONNECTIVITY_SERVICE);
        }

        if (action.equals("enable")) {
            this.enableCellularRoute(callbackContext);
            return true;
        } else if (action.equals("disable")) {
            this.disableCellularRoute(callbackContext);
            return true;
        } else if (action.equals("registerListener")) {
            this.eventCallbackContext = callbackContext;
            PluginResult pluginResult = new PluginResult(PluginResult.Status.NO_RESULT);
            pluginResult.setKeepCallback(true);
            callbackContext.sendPluginResult(pluginResult);
            return true;
        } else if (action.equals("checkStatus")) {
            this.checkCurrentNetworkStatus(callbackContext);
            return true;
        }
        return false;
    }

    private void sendJsonEventToJS(String status, String data) {
        if (eventCallbackContext != null) {
            try {
                JSONObject json = new JSONObject();
                json.put("status", status);
                if (data != null) {
                    json.put("data", data);
                }
                PluginResult result = new PluginResult(PluginResult.Status.OK, json);
                result.setKeepCallback(true);
                eventCallbackContext.sendPluginResult(result);
            } catch (JSONException e) {}
        }
    }

    private void checkCurrentNetworkStatus(final CallbackContext callbackContext) {
        cordova.getThreadPool().execute(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONObject resultJson = new JSONObject();

                    // CRITICAL FIX: Explicitly scan all physical networks for a connected Wi-Fi interface
                    Network wifiNetwork = null;
                    Network cellularNetwork = null;

                    Network[] allNetworks = connectivityManager.getAllNetworks();
                    for (Network net : allNetworks) {
                        NetworkCapabilities caps = connectivityManager.getNetworkCapabilities(net);
                        if (caps != null) {
                            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                                wifiNetwork = net;
                            }
                            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                                cellularNetwork = net;
                            }
                        }
                    }

                    // CASE 1: Wi-Fi is physically connected. We MUST verify its specific health.
                    if (wifiNetwork != null) {
                        if (isInternetWorking(wifiNetwork)) {
                            // Wi-Fi is connected and its internet is perfectly fine
                            resultJson.put("status", "ONLINE");
                            resultJson.put("data", "WIFI");
                            callbackContext.success(resultJson);
                            return;
                        } else {
                            // Wi-Fi is connected but its internet connection is DEAD!
                            Log.w(TAG, "Wi-Fi interface connection detected but internet test failed.");

                            if (cellularNetwork != null) {
                                // Mobile data is available as a backup route
                                resultJson.put("status", "ONLINE_WIFI_DEAD");
                                resultJson.put("data", "WIFI");
                            } else {
                                // No mobile data fallback exists either
                                resultJson.put("status", "OFFLINE");
                            }
                            callbackContext.success(resultJson);
                            return;
                        }
                    }

                    // CASE 2: No Wi-Fi connected at all. Check fallback to default active route.
                    Network activeNetwork = null;
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        activeNetwork = connectivityManager.getActiveNetwork();
                    }

                    if (activeNetwork == null) {
                        resultJson.put("status", "OFFLINE");
                        callbackContext.success(resultJson);
                        return;
                    }

                    NetworkCapabilities activeCaps = connectivityManager.getNetworkCapabilities(activeNetwork);
                    if (activeCaps == null) {
                        resultJson.put("status", "OFFLINE");
                        callbackContext.success(resultJson);
                        return;
                    }

                    // Android checks the network's internet itself (the same generate_204 probe) and
                    // marks it VALIDATED - if so, no probe of our own is needed: that is what made a
                    // working mobile connection look OFFLINE now and then. Not validated (yet) -> one
                    // longer probe over that network.
                    boolean validated = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                            && activeCaps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
                    boolean works = validated || probeInternet(activeNetwork, CELLULAR_CONNECT_TIMEOUT_MS, CELLULAR_READ_TIMEOUT_MS);
                    Log.d(TAG, "checkStatus (no Wi-Fi): validated=" + validated + " works=" + works);

                    if (works) {
                        resultJson.put("status", "ONLINE");
                        if (activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                            resultJson.put("data", "MOBILE");
                        } else {
                            resultJson.put("data", "UNKNOWN");
                        }
                    } else {
                        resultJson.put("status", "OFFLINE");
                    }
                    callbackContext.success(resultJson);

                } catch (JSONException e) {
                    callbackContext.error("JSON formatting error: " + e.getMessage());
                }
            }
        });
    }

    private void enableCellularRoute(final CallbackContext callbackContext) {
        if (isForcingCellular) {
            callbackContext.success("Cellular routing already active.");
            return;
        }

        NetworkRequest.Builder builder = new NetworkRequest.Builder();
        builder.addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR);
        builder.addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);

        cellularCallback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(Network network) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    connectivityManager.bindProcessToNetwork(network);
                } else {
                    ConnectivityManager.setProcessDefaultNetwork(network);
                }
                isForcingCellular = true;
                sendJsonEventToJS("ONLINE", "MOBILE");
                callbackContext.success("Successfully forced app process to Cellular Data.");

                startWifiInternetMonitor();
            }

            @Override
            public void onLost(Network network) {
                clearBinding();
            }
        };

        try {
            connectivityManager.requestNetwork(builder.build(), cellularCallback);
        } catch (Exception e) {
            callbackContext.error("Failed to request cellular network: " + e.getMessage());
        }
    }

    // Actively re-probes both interfaces every RECOVERY_POLL_INTERVAL_MS while cellular is
    // forced, instead of relying solely on ConnectivityManager's onAvailable (which only fires
    // on a fresh connect/reconnect and misses a Wi-Fi network's internet recovering while it
    // stayed connected the whole time). Wi-Fi is always preferred back as soon as it's healthy.
    private void startWifiInternetMonitor() {
        if (recoveryHandler != null) return;

        recoveryHandler = new android.os.Handler(android.os.Looper.getMainLooper());
        recoveryRunnable = new Runnable() {
            @Override
            public void run() {
                if (!isForcingCellular) return;

                cordova.getThreadPool().execute(new Runnable() {
                    @Override
                    public void run() {
                        Network wifiNetwork = null;
                        Network cellularNetwork = null;
                        Network[] allNetworks = connectivityManager.getAllNetworks();
                        for (Network net : allNetworks) {
                            NetworkCapabilities caps = connectivityManager.getNetworkCapabilities(net);
                            if (caps != null) {
                                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) wifiNetwork = net;
                                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) cellularNetwork = net;
                            }
                        }

                        if (wifiNetwork != null && isInternetWorking(wifiNetwork)) {
                            Log.d(TAG, "Wi-Fi internet recovered, reverting from forced cellular.");
                            clearBinding();
                            sendJsonEventToJS("ONLINE", "WIFI");
                            return;
                        }

                        if (cellularNetwork == null || !isInternetWorking(cellularNetwork)) {
                            Log.w(TAG, "Forced cellular route has no working internet either.");
                            sendJsonEventToJS("OFFLINE", null);
                        }

                        if (isForcingCellular && recoveryHandler != null) {
                            recoveryHandler.postDelayed(recoveryRunnable, RECOVERY_POLL_INTERVAL_MS);
                        }
                    }
                });
            }
        };

        recoveryHandler.postDelayed(recoveryRunnable, RECOVERY_POLL_INTERVAL_MS);
    }

    // Retries a couple of times before concluding a network's internet is actually dead -
    // a single timed-out or blipped probe otherwise flips the UI on a purely transient hiccup.
    private boolean isInternetWorking(Network network) {
        for (int attempt = 1; attempt <= INTERNET_CHECK_ATTEMPTS; attempt++) {
            if (probeInternet(network)) {
                return true;
            }
            if (attempt < INTERNET_CHECK_ATTEMPTS) {
                try {
                    Thread.sleep(INTERNET_CHECK_RETRY_DELAY_MS);
                } catch (InterruptedException e) {
                    return false;
                }
            }
        }
        return false;
    }

    private boolean probeInternet(Network network) {
        return probeInternet(network, CONNECT_TIMEOUT_MS, READ_TIMEOUT_MS);
    }

    private boolean probeInternet(Network network, int connectTimeoutMs, int readTimeoutMs) {
        HttpURLConnection urlConnection = null;
        try {
            URL url = new URL("https://connectivitycheck.gstatic.com/generate_204");
            if (network != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                urlConnection = (HttpURLConnection) network.openConnection(url);
            } else {
                urlConnection = (HttpURLConnection) url.openConnection();
            }
            urlConnection.setInstanceFollowRedirects(false);
            urlConnection.setConnectTimeout(connectTimeoutMs);
            urlConnection.setReadTimeout(readTimeoutMs);
            urlConnection.setUseCaches(false);
            urlConnection.connect();
            return (urlConnection.getResponseCode() == 204);
        } catch (IOException e) {
            return false;
        } finally {
            if (urlConnection != null) {
                urlConnection.disconnect();
            }
        }
    }

    private void disableCellularRoute(CallbackContext callbackContext) {
        clearBinding();
        callbackContext.success("Returned app process routing to OS defaults.");
    }

    private void clearBinding() {
        isForcingCellular = false;
        if (cellularCallback != null) {
            try { connectivityManager.unregisterNetworkCallback(cellularCallback); } catch (Exception e) {}
            cellularCallback = null;
        }
        if (recoveryHandler != null) {
            recoveryHandler.removeCallbacks(recoveryRunnable);
            recoveryHandler = null;
            recoveryRunnable = null;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivityManager.bindProcessToNetwork(null);
        } else {
            ConnectivityManager.setProcessDefaultNetwork(null);
        }
    }
}
