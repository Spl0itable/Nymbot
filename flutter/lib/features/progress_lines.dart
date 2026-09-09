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
    case 'stage':
      return step.text == 'reading'
          ? t('Reading this conversation back off the relays')
          : '';
    case 'route':
      return step.flag
          ? t('Sending the picture to a model that can see it')
          : t('Taking the {task} route', {'task': routeLabel(step.text)});
    case 'search':
      return t('Searching the web for “{query}”', {'query': step.text});
    case 'page':
      return t('Reading {url}', {'url': step.text});
    case 'vision':
      return step.call > 1
          ? t('Looking at {n} pictures', {'n': step.call})
          : t('Looking at the picture');
    case 'model':
      return step.of > 1
          ? t('Model call {n} of {total}', {'n': step.call, 'total': step.of})
          : t('Asking {model}', {'model': step.text});
    case 'effort':
      return step.text == 'planning'
          ? t('Planning the answer before writing it')
          : t('Reading the answer back against the question');
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

/// Drops the steps that say what the line above already said.
List<TurnStep> trimProgress(List<TurnStep> steps) {
  final out = <TurnStep>[];
  for (final step in steps) {
    final before = out.isEmpty ? null : out.last;
    if (step.kind == 'model' &&
        step.of <= 1 &&
        before != null &&
        before.kind == 'routing' &&
        before.text == step.text) {
      continue;
    }
    out.add(step);
  }
  return out;
}

String routeLabel(String task) {
  switch (task) {
    case 'coding':
      return t('coding');
    case 'reasoning':
      return t('reasoning');
    case 'creative':
      return t('creative');
    case 'translation':
      return t('translation');
    default:
      return t('general');
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
    case 'recall':
      return t('Looking back through this chat');
    default:
      return t('Working');
  }
}
