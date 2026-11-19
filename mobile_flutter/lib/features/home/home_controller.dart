import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/error_messages.dart';
import '../../core/models/video_metadata.dart';
import '../../core/url_tools.dart';
import '../../data/providers.dart';
import '../downloads/downloads_state.dart';

enum HomePhase { idle, loading, loaded, error }

class HomeState {
  const HomeState({
    this.input = '',
    this.phase = HomePhase.idle,
    this.metadata,
    this.sourceUrl,
    this.selectedFormatId,
    this.error,
    this.isStarting = false,
    this.startError,
    this.addedJobId,
  });

  /// What is in the URL field (kept here so switching tabs doesn't lose it).
  final String input;
  final HomePhase phase;
  final VideoMetadata? metadata;

  /// The normalised link the metadata belongs to.
  final String? sourceUrl;
  final String? selectedFormatId;

  /// Why "Get formats" failed.
  final ErrorPresentation? error;

  final bool isStarting;

  /// Why "Download" failed (the formats stay on screen so the user can retry).
  final ErrorPresentation? startError;

  /// Set after a download was added: drives the inline "Added to Downloads" confirmation.
  final String? addedJobId;

  VideoUrlCheck get check => checkVideoUrl(input);

  FormatOption? get selectedFormat {
    final id = selectedFormatId;
    if (id == null) return null;
    for (final format in metadata?.formats ?? const <FormatOption>[]) {
      if (format.id == id) return format;
    }
    return null;
  }

  HomeState copyWith({
    String? input,
    HomePhase? phase,
    VideoMetadata? metadata,
    String? sourceUrl,
    String? selectedFormatId,
    ErrorPresentation? error,
    bool? isStarting,
    ErrorPresentation? startError,
    String? addedJobId,
    bool clearMetadata = false,
    bool clearSelection = false,
    bool clearError = false,
    bool clearStartError = false,
    bool clearAdded = false,
  }) => HomeState(
    input: input ?? this.input,
    phase: phase ?? this.phase,
    metadata: clearMetadata ? null : (metadata ?? this.metadata),
    sourceUrl: clearMetadata ? null : (sourceUrl ?? this.sourceUrl),
    selectedFormatId: clearSelection
        ? null
        : (selectedFormatId ?? this.selectedFormatId),
    error: clearError ? null : (error ?? this.error),
    isStarting: isStarting ?? this.isStarting,
    startError: clearStartError ? null : (startError ?? this.startError),
    addedJobId: clearAdded ? null : (addedJobId ?? this.addedJobId),
  );
}

final homeProvider = NotifierProvider<HomeController, HomeState>(
  HomeController.new,
);

class HomeController extends Notifier<HomeState> {
  int _requestSeq = 0;

  @override
  HomeState build() => const HomeState();

  void setInput(String value) {
    if (value == state.input) return;
    _requestSeq++; // an in-flight lookup for the old text must not land on the new one
    state = HomeState(input: value);
  }

  void clear() => setInput('');

  Future<void> fetchFormats() async {
    final check = state.check;
    if (!check.isValid || state.phase == HomePhase.loading) return;
    final seq = ++_requestSeq;
    state = HomeState(input: state.input, phase: HomePhase.loading);
    try {
      final metadata = await ref.read(apiProvider).metadata(check.url!);
      if (seq != _requestSeq) return;
      state = HomeState(
        input: state.input,
        phase: HomePhase.loaded,
        metadata: metadata,
        sourceUrl: check.url,
      );
    } on ApiException catch (error) {
      if (seq != _requestSeq) return;
      state = HomeState(
        input: state.input,
        phase: HomePhase.error,
        error: presentApiError(error),
      );
    }
  }

  void selectFormat(String id) {
    if (state.phase != HomePhase.loaded) return;
    state = state.copyWith(
      selectedFormatId: id,
      clearStartError: true,
      clearAdded: true,
    );
  }

  /// One tap = one download: a fresh idempotency key each time, and `isStarting` blocks a second tap.
  Future<void> startDownload() async {
    final format = state.selectedFormat;
    final metadata = state.metadata;
    final url = state.sourceUrl;
    if (format == null || metadata == null || url == null || state.isStarting) {
      return;
    }
    state = state.copyWith(
      isStarting: true,
      clearStartError: true,
      clearAdded: true,
    );
    try {
      final entry = await ref
          .read(downloadsProvider.notifier)
          .start(
            sourceUrl: url,
            metadata: metadata,
            format: format,
            idempotencyKey: ref.read(idGeneratorProvider)(),
          );
      state = state.copyWith(
        isStarting: false,
        addedJobId: entry.jobId,
        clearSelection: true,
      );
    } on ApiException catch (error) {
      state = state.copyWith(
        isStarting: false,
        startError: presentApiError(error),
      );
    } on Object {
      // Unexpected local failure: never leave the button stuck in its loading state.
      state = state.copyWith(
        isStarting: false,
        startError: const ErrorPresentation(
          message: genericFailureMessage,
          retryable: true,
        ),
      );
    }
  }

  void dismissConfirmation() => state = state.copyWith(clearAdded: true);
}
