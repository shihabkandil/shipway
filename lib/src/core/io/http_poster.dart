import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What came back from one request.
class HttpReply {
  const HttpReply({
    required this.statusCode,
    required this.body,
    this.retryAfter,
  });

  final int statusCode;
  final String body;

  /// `Retry-After`, when the server sent one with a 429.
  final Duration? retryAfter;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// Why a request produced no reply at all: no network, a refused connection,
/// a server that never answered.
class HttpPostException implements Exception {
  const HttpPostException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The one door to the network, as [ProcessRunner] is the one door to other
/// programs.
///
/// Notifications use it, and `shipway secrets check --verify`. Everything that
/// ships an app goes through fastlane, which owns its own networking; this
/// exists so that telling somebody about a release — or asking a service
/// whether a key is still good — is testable without the service.
abstract class HttpPoster {
  /// POSTs [body] as JSON to [url].
  ///
  /// Throws [HttpPostException] when there is no reply. An error status is a
  /// reply, and comes back as one.
  Future<HttpReply> postJson(
    Uri url,
    Object body, {
    Map<String, String> headers = const <String, String>{},
  });

  /// POSTs [fields] as `application/x-www-form-urlencoded` to [url].
  ///
  /// The shape an OAuth token endpoint takes, which is not JSON.
  Future<HttpReply> postForm(Uri url, Map<String, String> fields);

  /// GETs [url].
  ///
  /// Throws [HttpPostException] when there is no reply, as [postJson] does.
  Future<HttpReply> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
  });
}

class SystemHttpPoster implements HttpPoster {
  SystemHttpPoster({this.timeout = const Duration(seconds: 15)});

  /// For the whole exchange, not just connecting. A notification that hangs
  /// holds the end of a release hostage; one that gives up costs a message.
  final Duration timeout;

  @override
  Future<HttpReply> postJson(
    Uri url,
    Object body, {
    Map<String, String> headers = const <String, String>{},
  }) => _exchange(url, (client) async {
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    headers.forEach(request.headers.set);
    request.add(utf8.encode(jsonEncode(body)));
    return request;
  });

  @override
  Future<HttpReply> postForm(Uri url, Map<String, String> fields) =>
      _exchange(url, (client) async {
        final request = await client.postUrl(url);
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        request.add(utf8.encode(Uri(queryParameters: fields).query));
        return request;
      });

  @override
  Future<HttpReply> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
  }) => _exchange(url, (client) async {
    final request = await client.getUrl(url);
    headers.forEach(request.headers.set);
    return request;
  });

  /// One request and its reply, with every way of getting no reply turned
  /// into the same exception.
  Future<HttpReply> _exchange(
    Uri url,
    Future<HttpClientRequest> Function(HttpClient client) open,
  ) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await _send(client, open).timeout(timeout);
    } on TimeoutException {
      throw HttpPostException(
        '${url.host} did not answer within ${timeout.inSeconds}s',
      );
    } on SocketException catch (e) {
      // Only the host: the path of a webhook URL is the credential.
      throw HttpPostException(
        'could not reach ${url.host} (${e.osError?.message ?? e.message})',
      );
    } on HandshakeException catch (e) {
      throw HttpPostException('${url.host}: ${e.message}');
    } on HttpException catch (e) {
      throw HttpPostException('${url.host}: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpReply> _send(
    HttpClient client,
    Future<HttpClientRequest> Function(HttpClient client) open,
  ) async {
    final request = await open(client);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    final retryAfter = int.tryParse(
      response.headers.value(HttpHeaders.retryAfterHeader) ?? '',
    );
    return HttpReply(
      statusCode: response.statusCode,
      body: text,
      retryAfter: retryAfter == null ? null : Duration(seconds: retryAfter),
    );
  }
}
