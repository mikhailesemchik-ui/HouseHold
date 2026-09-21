import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/services/notification_service.dart';
import 'package:household_os/core/services/household_updates_push_settings.dart';
import 'package:household_os/core/services/remote_push_notification_service.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/services/reminder_settings.dart';
import 'package:household_os/core/services/widget_settings.dart';
import 'package:household_os/core/theme/app_radius.dart';
import 'package:household_os/core/theme/app_shadows.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_icon_chip.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_section_header.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/core/widgets/confirm_destructive.dart';
import 'package:household_os/features/profile/data/profile_repository.dart';
import 'package:household_os/features/profile/domain/profile.dart';
import 'package:household_os/features/profile/domain/profile_validation.dart';
import 'package:household_os/features/profile/presentation/profile_provider.dart';
import 'package:household_os/features/today/presentation/today_provider.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(currentProfileProvider);
    // The header is ordinary scrollable content now (not a pinned `AppBar`)
    // — every branch below places it as the first item of its own
    // scrollable, so it scrolls away with the page and returns naturally
    // at the top.
    const header = AppScreenHeader(title: 'Profile');
    return Scaffold(
      body: profileAsync.when(
        data: (profile) => _ProfileBody(header: header, profile: profile),
        loading: () => SafeArea(
          top: false,
          bottom: false,
          child: ListView(
            children: const [
              header,
              Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
          ),
        ),
        error: (_, _) => SafeArea(
          top: false,
          bottom: false,
          child: ListView(
            children: const [
              header,
              Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(
                  child: Text('Could not load profile. Please try again.'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileBody extends ConsumerStatefulWidget {
  const _ProfileBody({required this.header, required this.profile});

  final Widget header;
  final Profile profile;

  @override
  ConsumerState<_ProfileBody> createState() => _ProfileBodyState();
}

class _ProfileBodyState extends ConsumerState<_ProfileBody> {
  bool _remindersEnabled = false;
  bool _widgetShowNames = false;
  bool _householdUpdatesEnabled = false;
  bool _settingsLoaded = false;
  bool _isUpdatingAvatar = false;
  bool _isUpdatingName = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final reminders = await ReminderSettings.isEnabled();
    final householdUpdates = await HouseholdUpdatesPushSettings.isEnabled();
    final mode = await WidgetSettings.getPrivacyMode();
    if (mounted) {
      setState(() {
        _remindersEnabled = reminders;
        _widgetShowNames = mode == WidgetPrivacyMode.showNames;
        _householdUpdatesEnabled = householdUpdates;
        _settingsLoaded = true;
      });
    }
  }

  Future<void> _onWidgetPrivacyToggle(bool showNames) async {
    final mode = showNames
        ? WidgetPrivacyMode.showNames
        : WidgetPrivacyMode.countsOnly;
    await WidgetSettings.setPrivacyMode(mode);
    if (!mounted) return;
    setState(() => _widgetShowNames = showNames);
    ref.read(todayProvider.notifier).updateWidget().ignore();
  }

  Future<void> _onHouseholdUpdatesToggle(bool value) async {
    final registrar = SupabaseDevicePushTokenRegistrar(supabaseClient);
    final controller = HouseholdUpdatesPushController(
      tokenProvider: const MethodChannelPushTokenProvider(),
      preferenceStore:
          const SharedPreferencesHouseholdUpdatesPushPreferenceStore(),
      registerToken: (token, platform) =>
          registrar.registerCurrentUserToken(token: token, platform: platform),
      unregisterToken: registrar.unregisterCurrentUserToken,
      requestPermission: notificationService.requestPermission,
    );

    try {
      final enabled = await controller.setEnabled(value);
      if (!mounted) return;
      setState(() => _householdUpdatesEnabled = enabled);
      if (value && !enabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Household update notifications could not be enabled on this device.',
            ),
          ),
        );
      }
    } catch (_) {
      final enabled = await HouseholdUpdatesPushSettings.isEnabled();
      if (!mounted) return;
      setState(() => _householdUpdatesEnabled = enabled);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not update household notification setting.'),
        ),
      );
    }
  }

  Future<void> _onToggle(bool value) async {
    if (value) {
      final granted = await notificationService.requestPermission();
      if (!mounted) return;
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Notification permission denied. Enable it in device Settings.',
            ),
          ),
        );
        return;
      }
      await ReminderSettings.setEnabled(true);
      if (!mounted) return;
      setState(() => _remindersEnabled = true);
      ref.read(todayProvider.notifier).reconcileReminders().ignore();
    } else {
      await ReminderSettings.setEnabled(false);
      await notificationService.cancelAll();
      if (mounted) setState(() => _remindersEnabled = false);
    }
  }

  Future<void> _editDisplayName() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) =>
          _EditDisplayNameDialog(initialValue: widget.profile.displayName),
    );
    if (result == null || !mounted) return;

    setState(() => _isUpdatingName = true);
    try {
      final repo = ProfileRepository(supabaseClient);
      await repo.updateDisplayName(widget.profile.userId, result);
      ref.invalidate(currentProfileProvider);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update name. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _isUpdatingName = false);
    }
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    setState(() => _isUpdatingAvatar = true);
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.')
          ? picked.name.split('.').last
          : 'jpg';
      final mimeType = _mimeFromExt(ext);
      final repo = ProfileRepository(supabaseClient);
      final url = await repo.uploadAvatar(
        widget.profile.userId,
        bytes,
        mimeType,
        ext,
      );
      await repo.setAvatarUrl(widget.profile.userId, url);
      ref.invalidate(currentProfileProvider);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not upload avatar. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _isUpdatingAvatar = false);
    }
  }

  Future<void> _removeAvatar() async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Remove photo?',
      message: 'This removes your profile photo. This cannot be undone.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;

    setState(() => _isUpdatingAvatar = true);
    try {
      final repo = ProfileRepository(supabaseClient);
      await repo.setAvatarUrl(widget.profile.userId, null);
      await repo.deleteAvatarFiles(widget.profile.userId);
      ref.invalidate(currentProfileProvider);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not remove avatar. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _isUpdatingAvatar = false);
    }
  }

  void _showAvatarSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose photo'),
              onTap: () {
                Navigator.pop(context);
                _pickAvatar();
              },
            ),
            if (widget.profile.avatarUrl != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove photo'),
                onTap: () {
                  Navigator.pop(context);
                  _removeAvatar();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _copyPublicId() {
    Clipboard.setData(ClipboardData(text: widget.profile.publicId));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('ID copied to clipboard.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final avatarUrl = widget.profile.avatarUrl;

    return ListView(
      // Explicit padding: bottom only (the shell's measured nav bar height,
      // exactly the clearance the last settings row needs). The top inset is
      // deliberately NOT consumed here — `AppScreenHeader` reserves its own
      // top spacing, so this list's viewport can extend to the physical
      // screen edge and let scrolled content pass under the status-bar haze.
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      children: [
        widget.header,
        const SizedBox(height: AppSpacing.xl),
        // ── Identity card ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          child: AppSoftCard(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.base,
              vertical: AppSpacing.lg,
            ),
            child: Column(
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    GestureDetector(
                      onTap: _isUpdatingAvatar ? null : _showAvatarSheet,
                      child: ExcludeSemantics(
                        child: CircleAvatar(
                          radius: 44,
                          backgroundColor: colorScheme.primary.withValues(
                            alpha: 0.14,
                          ),
                          backgroundImage: avatarUrl != null
                              ? NetworkImage(avatarUrl)
                              : null,
                          child: _isUpdatingAvatar
                              ? const CircularProgressIndicator()
                              : avatarUrl == null
                              ? Icon(
                                  Icons.person,
                                  size: 44,
                                  color: colorScheme.primary,
                                )
                              : null,
                        ),
                      ),
                    ),
                    // Was a bare 28dp GestureDetector — below the 48dp
                    // minimum touch target and with no tooltip/semantic
                    // label. IconButton keeps the same small visual badge
                    // while giving it a real (default, non-shrink-wrapped)
                    // tap area and label; the big avatar above leads to the
                    // same sheet, so the badge is purely a visual cue and is
                    // excluded from semantics to avoid a duplicate "Edit
                    // profile photo" announcement.
                    if (!_isUpdatingAvatar)
                      IconButton(
                        onPressed: _showAvatarSheet,
                        tooltip: 'Edit profile photo',
                        icon: CircleAvatar(
                          radius: 14,
                          backgroundColor: colorScheme.primary,
                          child: Icon(
                            Icons.edit_rounded,
                            size: 13,
                            color: colorScheme.onPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.base),
                // ── Display name ──────────────────────────────────────────
                // A leading spacer mirrors the trailing IconButton's own
                // footprint (gap + its guaranteed minimum touch target), so
                // `MainAxisAlignment.center` centers the TEXT itself under
                // the avatar rather than centering the text+icon group —
                // which would leave the text visibly shifted left.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: AppSpacing.xs + kMinInteractiveDimension,
                    ),
                    Flexible(
                      child: _isUpdatingName
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              widget.profile.displayName,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.4,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    IconButton(
                      // Kept distinct from the avatar badge's `edit_rounded`
                      // so the two edit affordances remain individually
                      // targetable (visually and in tests).
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: 'Edit name',
                      onPressed: _isUpdatingName ? null : _editDisplayName,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                // ── Public ID — visibly secondary to the name above ────────
                // Same leading-spacer mirroring as the name row above, sized
                // to this row's own trailing action.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: AppSpacing.xs + kMinInteractiveDimension,
                    ),
                    Text(
                      widget.profile.publicId,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            letterSpacing: 0.5,
                          )
                          .tabular,
                    ),
                    // Was a bare 14dp GestureDetector — below the 48dp
                    // minimum touch target. IconButton keeps the same
                    // compact glyph while giving it a real (default,
                    // non-compact) tap area.
                    IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 14),
                      tooltip: 'Copy ID',
                      color: colorScheme.onSurfaceVariant,
                      onPressed: _copyPublicId,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        // ── Notifications group ─────────────────────────────────────────────
        const AppSectionHeader(label: 'Notifications'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          child: _settingsLoaded
              ? _SettingsGroupCard(
                  rows: [
                    SwitchListTile(
                      secondary: AppIconChip(
                        icon: Icons.notifications_rounded,
                        background: colorScheme.primary.withValues(alpha: 0.10),
                        foreground: colorScheme.primary,
                        size: 32,
                        iconSize: 16,
                      ),
                      title: const Text('Task reminders'),
                      subtitle: const Text(
                        'Notify me when a scheduled task is due',
                      ),
                      value: _remindersEnabled,
                      onChanged: _onToggle,
                    ),
                    SwitchListTile(
                      secondary: AppIconChip(
                        icon: Icons.groups_rounded,
                        background: colorScheme.primary.withValues(alpha: 0.10),
                        foreground: colorScheme.primary,
                        size: 32,
                        iconSize: 16,
                      ),
                      title: const Text('Household updates'),
                      subtitle: const Text(
                        'Notify me when another member changes this household',
                      ),
                      value: _householdUpdatesEnabled,
                      onChanged: _onHouseholdUpdatesToggle,
                    ),
                  ],
                )
              : const _SettingsGroupCard(rows: [_SettingsGroupLoadingRow()]),
        ),
        const SizedBox(height: AppSpacing.lg),
        // ── Widget group ─────────────────────────────────────────────────────
        const AppSectionHeader(label: 'Widget'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          child: _settingsLoaded
              ? _SettingsGroupCard(
                  rows: [
                    SwitchListTile(
                      secondary: AppIconChip(
                        icon: Icons.widgets_rounded,
                        background: colorScheme.primary.withValues(alpha: 0.10),
                        foreground: colorScheme.primary,
                        size: 32,
                        iconSize: 16,
                      ),
                      title: const Text('Show task names'),
                      subtitle: const Text(
                        'Display task names on the home-screen widget',
                      ),
                      value: _widgetShowNames,
                      onChanged: _onWidgetPrivacyToggle,
                    ),
                  ],
                )
              : const _SettingsGroupCard(rows: [_SettingsGroupLoadingRow()]),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Grouped settings surface — one soft elevated group (`AppRadius.group`,
// one restrained shadow) holding several inner rows separated only by a
// quiet hairline, never a second drop shadow (`docs/new_design`: avoids
// "card inside card inside card" nesting).
// ---------------------------------------------------------------------------

class _SettingsGroupCard extends StatelessWidget {
  const _SettingsGroupCard({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.group),
        ),
        shadows: AppShadows.card,
      ),
      child: Material(
        color: colorScheme.surfaceBright,
        borderRadius: BorderRadius.circular(AppRadius.group),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final (i, row) in rows.indexed) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  indent: AppSpacing.base,
                  endIndent: AppSpacing.base,
                  color: colorScheme.outlineVariant,
                ),
              row,
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsGroupLoadingRow extends StatelessWidget {
  const _SettingsGroupLoadingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.base,
      ),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _EditDisplayNameDialog extends StatefulWidget {
  const _EditDisplayNameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_EditDisplayNameDialog> createState() => _EditDisplayNameDialogState();
}

class _EditDisplayNameDialogState extends State<_EditDisplayNameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final error = validateDisplayName(_controller.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: displayNameMaxLength,
        decoration: InputDecoration(
          labelText: 'Display name',
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

String _mimeFromExt(String ext) {
  switch (ext.toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    default:
      return 'image/jpeg';
  }
}
