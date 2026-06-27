var exec = require('cordova/exec');

var ForceMobileData = {
    enable: function (successCallback, errorCallback) {
        exec(successCallback, errorCallback, 'ForceMobileData', 'enable', []);
    },
    disable: function (successCallback, errorCallback) {
        exec(successCallback, errorCallback, 'ForceMobileData', 'disable', []);
    },
    registerListener: function (eventCallback, errorCallback) {
        exec(eventCallback, errorCallback, 'ForceMobileData', 'registerListener', []);
    }
};

module.exports = ForceMobileData;
