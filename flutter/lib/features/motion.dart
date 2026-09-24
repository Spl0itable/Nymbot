import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/workspace.dart';

bool reducedMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

void announceReply(AppSettings settings) {
  if (settings.soundOnReply) {
    unawaited(SystemSound.play(SystemSoundType.click));
  }
  if (settings.hapticOnReply) unawaited(HapticFeedback.lightImpact());
}
