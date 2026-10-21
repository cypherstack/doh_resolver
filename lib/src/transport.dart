import 'dart:async';

import 'dns.dart';

/// A started request. Starting never throws: every failure completes [result]
/// with a [DohResolverException], and an unawaited [result] never raises an
/// uncaught error.
class DohResolverOperation<T> {
  final Future<T> result;

  /// Fails an unfinished operation and releases its work. Repeated calls are
  /// safe.
  final void Function() cancel;
  DohResolverOperation(this.result, this.cancel) {
    result.ignore();
  }

  /// The error is reported only to listeners of [result]; dropping it is safe.
  DohResolverOperation.failed(DohResolverException error)
      : this(Future<T>.error(error), _noop);
}

void _noop() {}

/// The body of a 200 response from a DoH resolver.
class DohResolverResponse {
  final List<int> body;

  /// Time the response spent in HTTP caches, from its `Age` header.
  final Duration age;
  DohResolverResponse(List<int> body, {this.age = Duration.zero})
      : body = List.unmodifiable(body) {
    if (age < Duration.zero) throw ArgumentError.value(age, 'age');
  }
}

/// Sends the HTTPS GET requests of a [DohResolver].
///
/// Implementations must:
/// - deliver only 200 responses, failing any other status with
///   [DohResolverHttpStatusException];
/// - deliver every failure through [DohResolverOperation.result] instead of
///   throwing from [start], completing it with a [DohResolverException] of
///   their choosing, such as [DohResolverTransportTimeoutException] or
///   [DohResolverCancelledException] with reason
///   [DohResolverCancellationReason.transportClosed]. Any other error is
///   wrapped as a [DohResolverTransportException];
/// - make [DohResolverOperation.cancel] idempotent;
/// - verify the server certificate and enforce `maxResponseBytes` while
///   reading, failing with [DohResolverResponseTooLargeException];
/// - send `mediaType` as `Accept` and fail a response whose `Content-Type`
///   has another media type.
abstract interface class DohResolverTransport {
  DohResolverOperation<DohResolverResponse> start(Uri uri,
      {required String mediaType, required int maxResponseBytes});
}
