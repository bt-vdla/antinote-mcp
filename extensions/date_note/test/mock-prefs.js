var prefs = {};
if (typeof getExtensionPreference === 'undefined') { var getExtensionPreference = function(ext, key){ return prefs[key]; }; }
