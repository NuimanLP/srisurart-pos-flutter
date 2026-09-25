// Web implementation of [isTransportFailure] — see transport_failure.dart.

import 'dart:async';

import 'package:http/http.dart' as http;

/// `BrowserClient` raises [http.ClientException] for every network error, and
/// `ApiTimeoutException` is one too.
bool isTransportFailure(Object error) =>
    error is http.ClientException || error is TimeoutException;
