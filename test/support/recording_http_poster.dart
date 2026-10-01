import 'dart:convert';

import 'package:shipway/src/core/io/http_poster.dart';

/// One captured POST.
class RecordedPost {
  RecordedPost(this.url, this.body, this.headers);

  final Uri url;
  final Object body;
  final Map<String, String> headers;

  /// The body as the JSON a server would have received.
  Map<String, dynamic> get json =>
      jsonDecode(jsonEncode(body)) as Map<String, dynamic>;

  String get method => url.pathSegments.isEmpty ? '' : url.pathSegments.last;
}

/// One captured GET or form POST.
class RecordedRequest {
  RecordedRequest(this.method, this.url, {this.headers, this.fields});

  /// `GET` or `POST`.
  final String method;
  final Uri url;
  final Map<String, String>? headers;

  /// The form fields of a POST.
  final Map<String, String>? fields;
}

/// An [HttpPoster] that sends nothing and remembers everything.
///
/// Answers `ok` by default — the body a webhook returns — and a Web API
/// success with a channel id and timestamp for anything under `/api/`, so a
/// test states only the replies it cares about.
class RecordingHttpPoster implements HttpPoster {
  final List<RecordedPost> posts = <RecordedPost>[];

  /// Every GET and form POST, in order. Kept apart from [posts], which the
  /// notification tests index into.
  final List<RecordedRequest> requests = <RecordedRequest>[];

  /// Answers in order before falling back to the defaults. An entry that is an
  /// [HttpPostException] is thrown instead.
  final List<Object> replies = <Object>[];

  @override
  Future<HttpReply> postJson(
    Uri url,
    Object body, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    posts.add(RecordedPost(url, body, headers));
    if (replies.isNotEmpty) {
      final next = replies.removeAt(0);
      if (next is HttpPostException) throw next;
      return next as HttpReply;
    }
    if (url.path.contains('/api/')) {
      return HttpReply(
        statusCode: 200,
        body: jsonEncode(<String, Object>{
          'ok': true,
          'channel': 'C0RELEASES',
          'ts': '1700000000.000100',
        }),
      );
    }
    return const HttpReply(statusCode: 200, body: 'ok');
  }

  @override
  Future<HttpReply> postForm(Uri url, Map<String, String> fields) async {
    requests.add(RecordedRequest('POST', url, fields: fields));
    return _next();
  }

  @override
  Future<HttpReply> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    requests.add(RecordedRequest('GET', url, headers: headers));
    return _next();
  }

  /// Fails loudly rather than inventing a success: a credential check that
  /// passes because nothing was stubbed proves nothing.
  HttpReply _next() {
    if (replies.isEmpty) {
      throw StateError('No reply stubbed for ${requests.last.url}');
    }
    final next = replies.removeAt(0);
    if (next is HttpPostException) throw next;
    return next as HttpReply;
  }
}
