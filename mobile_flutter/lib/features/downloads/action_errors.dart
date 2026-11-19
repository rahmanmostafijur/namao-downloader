import '../../core/api/api_exception.dart';
import '../../core/error_messages.dart';

/// Wording for a failed user action (cancel, retry) shown in a snackbar.
String describeActionError(Object error) {
  if (error is ApiException) return presentApiError(error).message;
  return "Couldn't complete that action.";
}
