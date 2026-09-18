import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:household_os/app/theme/app_shell_metrics.dart';
import 'package:household_os/core/theme/app_shadows.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_circle_icon_button.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_icon_chip.dart';
import 'package:household_os/core/widgets/app_pressable_scale.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/core/widgets/app_state_switcher.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/features/homes/data/household_repository.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';

class HomesScreen extends ConsumerWidget {
  const HomesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final homesAsync = ref.watch(homesProvider);
    // The header is ordinary scrollable content now (not a pinned `AppBar`)
    // — each branch below places it as the first item of its own scrollable
    // so it scrolls away with the page and returns naturally at the top.
    final header = AppScreenHeader(
      title: 'Homes',
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.xs),
          child: AppCircleIconButton(
            icon: Icons.group_add,
            tooltip: 'Join home',
            onPressed: () => _showJoinDialog(context, ref),
          ),
        ),
      ],
    );
    return Scaffold(
      // The outer shell scaffold has extendBody: true, so the outer nav bar
      // is rendered on top of everything in the body — meaning an inner
      // scaffold floatingActionButton sits behind it. Instead, position the
      // FAB inside a Stack so it's at the correct on-screen coordinates.
      body: Stack(
        children: [
          AppStateSwitcher(
            // Keyed by state *category*, not by the list itself — a
            // realtime addition/removal that keeps the list non-empty
            // stays on the 'data' key and never re-triggers the transition.
            stateKey: homesAsync.when(
              loading: () => 'loading',
              error: (_, _) => 'error',
              data: (homes) => homes.isEmpty ? 'empty' : 'data',
            ),
            child: homesAsync.when(
              loading: () => SafeArea(
                bottom: false,
                child: ListView(
                  children: [
                    header,
                    const AppSkeletonList(
                      sectionCounts: {'': 4},
                      scrollable: false,
                    ),
                  ],
                ),
              ),
              error: (_, _) => SafeArea(
                bottom: false,
                child: ListView(
                  children: [
                    header,
                    AppErrorState(
                      message: 'Could not load homes. Please try again.',
                      onRetry: () => ref.invalidate(homesProvider),
                    ),
                  ],
                ),
              ),
              data: (homes) => homes.isEmpty
                  ? _EmptyHomes(
                      header: header,
                      onCreate: () => _showCreateDialog(context, ref),
                      onJoin: () => _showJoinDialog(context, ref),
                    )
                  : _HomesList(header: header, homes: homes),
            ),
          ),
          // FAB: only when homes exist. Positioned above the glass nav bar
          // using the bottom inset (which includes the outer nav bar height).
          homesAsync.maybeWhen(
            data: (homes) => homes.isNotEmpty
                ? Positioned(
                    right: AppSpacing.base,
                    // A Positioned child never consumes MediaQuery padding
                    // itself, so the nav clearance is applied explicitly.
                    bottom: context.shellBottomInset + AppSpacing.base,
                    // A true pill (`docs/new_design`) with its own soft
                    // green-tinted glow, rather than the theme's default
                    // dark elevation shadow — `elevation: 0` here so the two
                    // don't stack.
                    child: AppPressableScale(
                      child: DecoratedBox(
                        decoration: const ShapeDecoration(
                          shape: StadiumBorder(),
                          shadows: AppShadows.primaryCta,
                        ),
                        child: FloatingActionButton.extended(
                          onPressed: () => _showCreateDialog(context, ref),
                          label: const Text('New home'),
                          icon: const Icon(Icons.add_rounded),
                          shape: const StadiumBorder(),
                          elevation: 0,
                          focusElevation: 0,
                          hoverElevation: 0,
                          highlightElevation: 0,
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (_) => const _CreateHouseholdDialog(),
    );
  }

  Future<void> _showJoinDialog(BuildContext context, WidgetRef ref) async {
    final household = await showDialog<Household>(
      context: context,
      builder: (_) => const _JoinHouseholdDialog(),
    );
    if (household != null && context.mounted) {
      context.go('/homes/${household.id}');
    }
  }
}

class _EmptyHomes extends StatelessWidget {
  const _EmptyHomes({
    required this.header,
    required this.onCreate,
    required this.onJoin,
  });

  final Widget header;
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    // Scrollable (with the header as its first child) so the header scrolls
    // away with the rest of the page, and the copy + both actions stay
    // reachable on a short viewport or at a large text scale, while still
    // sitting centred whenever there is room. SafeArea keeps the last
    // action clear of the nav bar.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: SafeArea(
          child: Column(
            children: [
              header,
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const AppEmptyState(
                      icon: Icons.home_outlined,
                      title: 'No homes yet',
                      subtitle:
                          'Create a home to start managing tasks, shopping, and expenses together.',
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    FilledButton(
                      onPressed: onCreate,
                      child: const Text('Create home'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton(
                      onPressed: onJoin,
                      child: const Text('Join home'),
                    ),
                    const SizedBox(height: AppSpacing.xxl),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomesList extends StatelessWidget {
  const _HomesList({required this.header, required this.homes});

  final Widget header;
  final List<Household> homes;

  @override
  Widget build(BuildContext context) {
    // SafeArea handles the top status-bar inset the removed AppBar used to
    // consume; explicit `top`/`bottom` padding below is unrelated visual
    // spacing / nav+FAB clearance, unchanged from before.
    return SafeArea(
      bottom: false,
      child: ListView.separated(
        padding: EdgeInsets.only(
          left: AppSpacing.base,
          right: AppSpacing.base,
          top: AppSpacing.sm,
          // Explicit padding opts out of automatic MediaQuery consumption, so
          // the nav clearance is re-applied here, plus room for the FAB.
          bottom: context.shellBottomInset + kFabClearance,
        ),
        // +1 for the header, kept in the same lazy builder-backed list as
        // the (potentially long) household rows — no separate scrollable.
        itemCount: homes.length + 1,
        // Each row is now its own elevated card (`docs/new_design`) — a gap
        // between them, not a shared hairline.
        separatorBuilder: (context, i) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, index) =>
            index == 0 ? header : _HomeRow(household: homes[index - 1]),
      ),
    );
  }
}

/// An individual elevated destination card (`docs/new_design`) — identity
/// icon, name, a quiet real metadata line. Whole-card tap target.
class _HomeRow extends ConsumerWidget {
  const _HomeRow({required this.household});

  final Household household;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // Reuses the existing per-household summary provider — no new query.
    final summaryAsync = ref.watch(householdSummaryProvider(household.id));
    final metric = summaryAsync.maybeWhen(
      data: (s) {
        final tasks =
            '${s.incompleteTaskCount} '
            '${s.incompleteTaskCount == 1 ? 'task' : 'tasks'}';
        final members =
            '${s.activeMemberCount} '
            '${s.activeMemberCount == 1 ? 'member' : 'members'}';
        return '$tasks · $members';
      },
      orElse: () => null,
    );
    final semanticLabel = metric == null
        ? household.name
        : '${household.name}, $metric';

    return AppSoftCard(
      onTap: () => context.go('/homes/${household.id}'),
      child: Semantics(
        label: semanticLabel,
        button: true,
        excludeSemantics: true,
        container: true,
        child: Row(
          children: [
            AppIconChip(
              icon: Icons.home_rounded,
              background: colorScheme.primary.withValues(alpha: 0.10),
              foreground: colorScheme.primary,
              size: 40,
              iconSize: 20,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    household.name,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (metric != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      metric,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Icon(
              Icons.chevron_right,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.55),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateHouseholdDialog extends ConsumerStatefulWidget {
  const _CreateHouseholdDialog();

  @override
  ConsumerState<_CreateHouseholdDialog> createState() =>
      _CreateHouseholdDialogState();
}

class _CreateHouseholdDialogState
    extends ConsumerState<_CreateHouseholdDialog> {
  final _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _fieldError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _controller.text;
    final validationError = Household.validateName(name);
    if (validationError != null) {
      setState(() => _fieldError = validationError);
      return;
    }
    setState(() {
      _isSubmitting = true;
      _fieldError = null;
    });
    try {
      await ref.read(homesProvider.notifier).createHousehold(name);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _fieldError = 'Failed to create home. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New home'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Home name',
          errorText: _fieldError,
        ),
        textCapitalization: TextCapitalization.words,
        onSubmitted: _isSubmitting ? null : (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}

class _JoinHouseholdDialog extends ConsumerStatefulWidget {
  const _JoinHouseholdDialog();

  @override
  ConsumerState<_JoinHouseholdDialog> createState() =>
      _JoinHouseholdDialogState();
}

class _JoinHouseholdDialogState extends ConsumerState<_JoinHouseholdDialog> {
  final _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _fieldError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final raw = _controller.text;
    final validationError = HouseholdRepository.validateInviteCode(raw);
    if (validationError != null) {
      setState(() => _fieldError = validationError);
      return;
    }
    setState(() {
      _isSubmitting = true;
      _fieldError = null;
    });
    try {
      final household = await ref
          .read(homesProvider.notifier)
          .joinHousehold(raw);
      if (mounted) Navigator.of(context).pop(household);
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _fieldError = _friendlyError(e);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _fieldError = 'Failed to join home. Please try again.';
        });
      }
    }
  }

  static String _friendlyError(PostgrestException e) {
    final code = e.code ?? '';
    final msg = e.message.toLowerCase();
    if (code == 'HO004' ||
        msg.contains('invalid') ||
        msg.contains('expired') ||
        msg.contains('revoked')) {
      return 'This invite code is invalid, expired, or has been revoked.';
    }
    return 'Failed to join home. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join home'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Invite code',
          hintText: 'ABCD-EFGH',
          errorText: _fieldError,
        ),
        textCapitalization: TextCapitalization.characters,
        onSubmitted: _isSubmitting ? null : (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Join'),
        ),
      ],
    );
  }
}
