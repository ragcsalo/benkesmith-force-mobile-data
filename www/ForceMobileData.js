var exec = require('cordova/exec');

var ForceMobileData = {
    enable: function (successCallback, errorCallback) {
        exec(successCallback, errorCallback, 'ForceMobileData', 'enable', []);
    },
    disable: function (successCallback, errorCallback) {
        exec(successCallback, errorCallback, 'ForceMobileData', 'disable', []);
    }
};

module.exports = ForceMobileData;