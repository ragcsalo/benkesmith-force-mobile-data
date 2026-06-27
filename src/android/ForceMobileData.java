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
    private ConnectivityManager connectivityManager;
    private ConnectivityManager.NetworkCallback cellularCallback;
    private ConnectivityManager.NetworkCallback wifiMonitorCallback;
    private CallbackContext eventCallbackContext;
    private boolean isForcingCellular = false;

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

                    if (isInternetWorking(null)) {
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

    private void startWifiInternetMonitor() {
        if (wifiMonitorCallback != null) return;

        NetworkRequest.Builder builder = new NetworkRequest.Builder();
        builder.addTransportType(NetworkCapabilities.TRANSPORT_WIFI);

        wifiMonitorCallback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(final Network network) {
                cordova.getThreadPool().execute(new Runnable() {
                    @Override
                    public void run() {
                        if (isInternetWorking(network)) {
                            Log.d(TAG, "Stable Wi-Fi internet detected! Reverting network route.");
                            clearBinding();
                            sendJsonEventToJS("ONLINE", "WIFI");
                        }
                    }
                });
            }
        };

        try {
            connectivityManager.registerNetworkCallback(builder.build(), wifiMonitorCallback);
        } catch (Exception e) {
            Log.e(TAG, "Error registering Wi-Fi monitor: " + e.getMessage());
        }
    }

    private boolean isInternetWorking(Network network) {
        HttpURLConnection urlConnection = null;
        try {
            URL url = new URL("https://connectivitycheck.gstatic.com/generate_204");
            if (network != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                urlConnection = (HttpURLConnection) network.openConnection(url);
            } else {
                urlConnection = (HttpURLConnection) url.openConnection();
            }
            urlConnection.setInstanceFollowRedirects(false);
            urlConnection.setConnectTimeout(3000);
            urlConnection.setReadTimeout(3000);
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
        if (wifiMonitorCallback != null) {
            try { connectivityManager.unregisterNetworkCallback(wifiMonitorCallback); } catch (Exception e) {}
            wifiMonitorCallback = null;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivityManager.bindProcessToNetwork(null);
        } else {
            ConnectivityManager.setProcessDefaultNetwork(null);
        }
    }
}
