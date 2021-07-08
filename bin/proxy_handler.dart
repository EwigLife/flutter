import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:path/path.dart' as p;
import 'package:pedantic/pedantic.dart';

// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file [https://github.com/dart-lang/shelf_proxy].

/// A handler that proxies requests to [url].
///
/// To generate the proxy request, this concatenates [url] and [Request.url].
/// This means that if the handler mounted under `/documentation` and [url] is
/// `http://example.com/docs`, a request to `/documentation/tutorials`
/// will be proxied to `http://example.com/docs/tutorials`.
///
/// [url] must be a [String] or [Uri].
///
/// [client] is used internally to make HTTP requests. It defaults to a
/// `dart:io`-based client.
///
/// [proxyName] is used in headers to identify this proxy. It should be a valid
/// HTTP token or a hostname. It defaults to `shelf_proxy`.
Handler proxyHandler(url, {http.Client client, String proxyName}) {
  Uri uri;
  if (url is String) {
    uri = Uri.parse(url);
  } else if (url is Uri) {
    uri = url;
  } else {
    throw ArgumentError.value(url, 'url', 'url must be a String or Uri.');
  }
  client ??= http.Client();
  proxyName ??= 'shelf_proxy';

  return (serverRequest) async {
    var requestUrl = uri.resolve(serverRequest.url.toString());

    //
    // Insertion of the business logic
    //
    if (_needsRedirection(requestUrl.path)){
      requestUrl = Uri.parse(url + "/index.html");
    }

    var clientRequest = http.StreamedRequest(serverRequest.method, requestUrl);
    clientRequest.followRedirects = false;
    clientRequest.headers.addAll(serverRequest.headers);
    clientRequest.headers['Host'] = uri.authority;

    // Add a Via header. See
    // http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.45
    _addHeader(clientRequest.headers, 'via',
        '${serverRequest.protocolVersion} $proxyName');

    unawaited(store(serverRequest.read(), clientRequest.sink));
    var clientResponse = await client.send(clientRequest);
    // Add a Via header. See
    // http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.45
    _addHeader(clientResponse.headers, 'via', '1.1 $proxyName');

    // Remove the transfer-encoding since the body has already been decoded by
    // [client].
    clientResponse.headers.remove('transfer-encoding');

    // If the original response was gzipped, it will be decoded by [client]
    // and we'll have no way of knowing its actual content-length.
    if (clientResponse.headers['content-encoding'] == 'gzip') {
      clientResponse.headers.remove('content-encoding');
      clientResponse.headers.remove('content-length');

      // Add a Warning header. See
      // http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.2
      _addHeader(
          clientResponse.headers, 'warning', '214 $proxyName "GZIP decoded"');
    }

    // Make sure the Location header is pointing to the proxy server rather
    // than the destination server, if possible.
    if (clientResponse.isRedirect &&
        clientResponse.headers.containsKey('location')) {
      var location =
          requestUrl.resolve(clientResponse.headers['location']).toString();
      if (p.url.isWithin(uri.toString(), location)) {
        clientResponse.headers['location'] =
            '/' + p.url.relative(location, from: uri.toString());
      } else {
        clientResponse.headers['location'] = location;
      }
    }

    return Response(clientResponse.statusCode,
        body: clientResponse.stream, headers: clientResponse.headers);
  };

}

/// Use [proxyHandler] instead.
@deprecated
Handler createProxyHandler(Uri rootUri) => proxyHandler(rootUri);

/// Add a header with [name] and [value] to [headers], handling existing headers
/// gracefully.
void _addHeader(Map<String, String> headers, String name, String value) {
  if (headers.containsKey(name)) {
    headers[name] += ', $value';
  } else {
    headers[name] = value;
  }
}

/// Pipes all data and errors from [stream] into [sink].
///
/// When [stream] is done, the returned [Future] is completed and [sink] is
/// closed if [closeSink] is true.
///
/// When an error occurs on [stream], that error is passed to [sink]. If
/// [cancelOnError] is true, [Future] will be completed successfully and no
/// more data or errors will be piped from [stream] to [sink]. If
/// [cancelOnError] and [closeSink] are both true, [sink] will then be
/// closed.
Future store(Stream stream, EventSink sink,
    {bool cancelOnError = true, bool closeSink = true}) {
  var completer = Completer();
  stream.listen(sink.add, onError: (e, StackTrace stackTrace) {
    sink.addError(e, stackTrace);
    if (cancelOnError) {
      completer.complete();
      if (closeSink) sink.close();
    }
  }, onDone: () {
    if (closeSink) sink.close();
    completer.complete();
  }, cancelOnError: cancelOnError);
  return completer.future;
}

///
/// Checks if the path requires to a redirection
///
bool _needsRedirection(String path){
  if (!path.startsWith("/")){
    return false;
  }

  final List<String> pathParts = path.substring(1).split('/');

  ///
  /// We only consider a path which is only made up of 1 part
  ///
  if (pathParts.isNotEmpty && pathParts.length == 1){
    final bool hasExtension = pathParts[0].split('.').length > 1;
    if (!hasExtension){
      return true;
    }
  }
  return false;
}