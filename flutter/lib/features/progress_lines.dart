import '../services/chat_engine.dart';
import 'i18n/i18n.dart';

/// What one progress step reads as. The worker sends facts; the words are the
/// client's, so they translate with everything else — and so both apps say the
/// same thing about the same step.
String progressLine(TurnStep step) {
  switch (step.kind) {
    case 'routing':
      return step.text.isNotEmpty && step.text != 'auto'
          ? t('Routing to {model}', {'model': step.text})
          : t('Routing this one');
    case 'search':
      return t('Searching the web for “{query}”', {'query': step.text});
    case 'model':
      return step.of > 1
          ? t('Model call {n} of {total}', {'n': step.call, 'total': step.of})
          : t('Asking {model}', {'model': step.text});
    case 'tool':
      return step.text.isNotEmpty
          ? '${toolLabel(step.tool)}: ${step.text}'
          : toolLabel(step.tool);
    case 'thinking':
      return step.text;
    default:
      return '';
  }
}

String toolLabel(String name) {
  switch (name) {
    case 'list_directory':
      return t('Listing files');
    case 'read_file':
      return t('Reading');
    case 'search_code':
      return t('Searching the code');
    case 'write_file':
      return t('Writing');
    case 'create_branch':
      return t('Creating a branch');
    case 'open_pull_request':
      return t('Opening a pull request');
    default:
      return t('Working');
  }
}
