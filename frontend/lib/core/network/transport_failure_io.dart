// Native (dart:io) implementation of [isTransportFailure] — see transport_failure.dart.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// [http.ClientException] covers `IOClient`'s wrapped socket errors and
/// `ApiTimeoutException`; [IOException] covers the ones it leaves raw.
bool isTransportFailure(Object error) =>
    error is http.ClientException ||
    error is TimeoutException ||
    error is IOException;
