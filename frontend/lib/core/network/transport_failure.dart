// Whether an error means "the request never got an answer" — a transport failure.
//
// Only this may send a money write down the offline path (#409, CLAUDE.md "only a
// 4xx is a verdict"): anything else raised after `api.post` returned — a 2xx whose
// body cannot be read, say — means the server DID answer and may have committed.
//
// Conditional import so the web build never pulls in `dart:io`: the IO side also
// accepts a raw `IOException` (`SocketException`, `HandshakeException`), which
// `IOClient` does not wrap in every case.
export 'transport_failure_web.dart'
    if (dart.library.io) 'transport_failure_io.dart';
