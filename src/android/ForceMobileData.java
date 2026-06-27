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
            // Keep a persistent channel open to send events to JS
            this.eventCallbackContext = callbackContext;
            PluginResult pluginResult = new PluginResult(PluginResult.Status.NO_RESULT);
            pluginResult.setKeepCallback(true);
            callbackContext.sendPluginResult(pluginResult);
            return true;
        }
        return false;
    }

    private void sendEventToJS(String status) {
        if (eventCallbackContext != null) {
            PluginResult result = new PluginResult(PluginResult.Status.OK, status);
            result.setKeepCallback(true);
            eventCallbackContext.sendPluginResult(result);
        }
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
                sendEventToJS("FORCING_MOBILE_DATA");
                callbackContext.success("Successfully forced app process to Cellular Data.");
                
                // Start monitoring Wi-Fi recovery
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
                // Run connection test in a separate thread to prevent blocking
                cordova.getThreadPool().execute(new Runnable() {
                    @Override
                    public void run() {
                        if (isWifiInternetWorking(network)) {
                            Log.d(TAG, "Stable Wi-Fi internet detected! Reverting network route.");
                            clearBinding();
                            sendEventToJS("SWITCHED_BACK_TO_WIFI");
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

    private boolean isWifiInternetWorking(Network network) {
        HttpURLConnection urlConnection = null;
        try {
            // Force this particular connection test to go exclusively through the Wi-Fi pipe
            URL url = new URL("https://connectivitycheck.gstatic.com/generate_204");
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
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
