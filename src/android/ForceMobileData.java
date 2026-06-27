package com.benkesmith.forcemobiledata;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.os.Build;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CallbackContext;
import org.json.JSONArray;
import org.json.JSONException;

public class ForceMobileData extends CordovaPlugin {

    private ConnectivityManager connectivityManager;
    private ConnectivityManager.NetworkCallback networkCallback;

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
        }
        return false;
    }

    private void enableCellularRoute(final CallbackContext callbackContext) {
        if (networkCallback != null) {
            callbackContext.success("Cellular routing already active or requested.");
            return;
        }

        NetworkRequest.Builder builder = new NetworkRequest.Builder();
        builder.addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR);
        builder.addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);

        networkCallback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(Network network) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    connectivityManager.bindProcessToNetwork(network);
                } else {
                    ConnectivityManager.setProcessDefaultNetwork(network);
                }
                // Send success message back to Cordova JS layer
                callbackContext.success("Successfully forced app process to Cellular Data.");
            }

            @Override
            public void onLost(Network network) {
                clearBinding();
            }
        };

        try {
            connectivityManager.requestNetwork(builder.build(), networkCallback);
        } catch (Exception e) {
            callbackContext.error("Failed to request cellular network: " + e.getMessage());
        }
    }

    private void disableCellularRoute(CallbackContext callbackContext) {
        clearBinding();
        callbackContext.success("Returned app process routing to OS defaults.");
    }

    private void clearBinding() {
        if (networkCallback != null) {
            try {
                connectivityManager.unregisterNetworkCallback(networkCallback);
            } catch (Exception e) {
                // Ignore if already unregistered
            }
            networkCallback = null;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivityManager.bindProcessToNetwork(null);
        } else {
            ConnectivityManager.setProcessDefaultNetwork(null);
        }
    }
}