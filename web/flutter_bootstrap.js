{{flutter_js}}
{{flutter_build_config}}

// The default loader also registers Flutter's flutter_service_worker.js, which
// would replace the app's own sw.js (see index.html) and then unregister
// itself, so it is left out here.
_flutter.loader.load();
