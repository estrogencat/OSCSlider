import 'package:flutter/material.dart';

import 'error_dialog.dart';
import 'osc_input_hub.dart';
import 'oscquery_client.dart';
import 'param_control.dart';
import 'vrchat_files.dart';

enum DiscoverySource { oscQuery, avatarFile, none }

class DiscoveryResult {
  final List<DiscoveredParam> params;
  final DiscoverySource source;
  final String? avatarName;
  // a short, human explanation when the list isn't the full live one.
  final String? problem;
  // the raw underlying error, for the "Details" button.
  final String? detail;

  const DiscoveryResult(this.params, this.source, {this.avatarName, this.problem, this.detail});
}

/// the shared "Discover" pipeline behind every discover button: find VRChat,
/// then get its parameter list from the best source available -
///
/// 1. VRChat's live OSCQuery tree (typed, with current values), else
/// 2. the avatar's saved OSC config file VRChat keeps in LocalLow (when
///    the OSCQuery server hangs, which it does on some complex avatars),
///    else
/// 3. nothing - the sheet then starts live highlighting so parameters can
///    still be found by moving them in-game.
Future<DiscoveryResult> loadDiscovery({required bool developerMode, required Duration timeout}) async {
  final lookup = await OscQueryClient.findVrchat(anyOscQueryService: developerMode, timeout: timeout);
  final endpoint = lookup.endpoint;
  String? avatarId = oscInputHub.lastAvatarId;
  String? failure;

  if (endpoint != null) {
    try {
      final params = await OscQueryClient.fetchAvatarParameters(endpoint, perAttemptTimeout: timeout);
      return DiscoveryResult(params, DiscoverySource.oscQuery);
    } catch (e) {
      failure = e.toString();
      avatarId = await OscQueryClient.fetchAvatarId(endpoint) ?? avatarId;
    }
  }

  if (avatarId != null) {
    final params = await VrchatFiles.avatarParameters(avatarId);
    if (params != null && params.isNotEmpty) {
      final name = await VrchatFiles.avatarName(avatarId);
      return DiscoveryResult(
        params,
        DiscoverySource.avatarFile,
        avatarName: name,
        problem: endpoint != null
            ? "VRChat's OSCQuery server didn't send the live parameter list (it can hang on complex "
                "avatars), so this is the list from VRChat's saved OSC config for your current avatar instead."
            : "VRChat's OSCQuery service wasn't found, so this is the list from VRChat's saved OSC "
                'config for the last avatar it reported.',
        detail: failure ?? lookup.error,
      );
    }
  }

  if (endpoint != null) {
    return DiscoveryResult(
      const [],
      DiscoverySource.none,
      problem: "Couldn't load the parameter list from VRChat - its OSCQuery server didn't respond in time "
          '(this can happen with especially complex avatars). Move something on your avatar and it\'ll '
          'show up below.',
      detail: failure,
    );
  }
  return DiscoveryResult(
    const [],
    DiscoverySource.none,
    problem: lookup.error != null
        ? 'Searching for VRChat failed. You can still add parameters by hand, or move something in '
            'VRChat with live highlighting on.'
        : 'VRChat wasn\'t found. Is it running with OSC enabled (Action Menu > Options > OSC)? You can '
            'still add parameters by hand below.',
    detail: lookup.error ?? oscNotFoundExplanation,
  );
}

/// pulls one parameter's current value from VRChat - read-only, nothing is
/// sent. shows a dialog explaining any failure and returns null then.
Future<Object?> fetchLiveValue(
  BuildContext context,
  ParamControl param, {
  required bool developerMode,
  required Duration timeout,
}) async {
  final lookup = await OscQueryClient.findVrchat(anyOscQueryService: developerMode, timeout: timeout);
  if (!context.mounted) return null;
  final endpoint = lookup.endpoint;
  if (endpoint == null) {
    await showErrorDialog(context, 'VRChat not found', lookup.error ?? oscNotFoundExplanation);
    return null;
  }
  try {
    final value = await OscQueryClient.fetchParameterValue(endpoint, oscAddressFor(param), timeout: timeout);
    if (value == null && context.mounted) {
      await showErrorDialog(
        context,
        'Unsupported value',
        '"${param.label}" exists on the avatar, but its value isn\'t a number or a bool.',
      );
    }
    return value;
  } on OscQueryException catch (e) {
    if (!context.mounted) return null;
    await showErrorDialog(
      context,
      e.notFound ? 'Parameter not found' : 'Could not fetch "${param.label}"',
      e.notFound
          ? 'The current avatar has no parameter at ${oscAddressFor(param)} - it may be named '
              'differently, or belong to another avatar.'
          : e.toString(),
    );
  } catch (e) {
    if (context.mounted) await showErrorDialog(context, 'Could not fetch "${param.label}"', e.toString());
  }
  return null;
}

/// every parameter's current value from VRChat in one request (the full
/// OSCQuery tree carries values). throws with a readable message.
Future<List<DiscoveredParam>> fetchAllLiveValues({required bool developerMode, required Duration timeout}) async {
  final lookup = await OscQueryClient.findVrchat(anyOscQueryService: developerMode, timeout: timeout);
  final endpoint = lookup.endpoint;
  if (endpoint == null) throw OscQueryException(lookup.error ?? oscNotFoundExplanation);
  return OscQueryClient.fetchAvatarParameters(endpoint, perAttemptTimeout: timeout);
}
