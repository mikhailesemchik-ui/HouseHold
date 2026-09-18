import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:household_os/app/theme/app_shell_metrics.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_glass.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_activity_row.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_icon_chip.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_section_header.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/core/widgets/confirm_destructive.dart';
import 'package:household_os/features/homes/data/household_repository.dart';
import 'package:household_os/features/homes/domain/household_invite.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';

class HouseholdDetailScreen extends ConsumerStatefulWidget {
  const HouseholdDetailScreen({super.key, required this.householdId});

  final String householdId;

  @override
  ConsumerState<HouseholdDetailScreen> createState() =>
      _HouseholdDetailScreenState();
}

class _HouseholdDetailScreenState extends ConsumerState<HouseholdDetailScreen> {
  bool _isCreatingInvite = false;

  HouseholdRepository get _repo => HouseholdRepository(supabaseClient);

  Future<void> _createInvite() async {
    if (_isCreatingInvite) return;
    setState(() => _isCreatingInvite = true);
    try {
      await _repo.createInvite(widget.householdId);
      ref.invalidate(householdInvitesProvider(widget.householdId));
    } catch (e, st) {
      debugPrint('createInvite error: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to create invite.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreatingInvite = false);
    }
  }

  Future<void> _revokeInvite(String inviteId) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Revoke invite?',
      message: 'This invite code will no longer work. This cannot be undone.',
      confirmLabel: 'Revoke',
    );
    if (!confirmed || !mounted) return;
    try {
      await _repo.revokeInvite(inviteId);
      ref.invalidate(householdInvitesProvider(widget.householdId));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to revoke invite.')),
        );
      }
    }
  }

  Future<void> _leaveHousehold() async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Leave home?',
      message:
          'You will lose access to this home. You can rejoin later with an invite code.',
      confirmLabel: 'Leave',
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(homesProvider.notifier).leaveHousehold(widget.householdId);
      if (mounted) context.go('/homes');
    } on PostgrestException catch (e) {
      if (!mounted) return;
      final message = _isOnlyOwnerError(e)
          ? 'You are the only owner. Assign another owner before leaving.'
          : 'Failed to leave home. Please try again.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to leave home. Please try again.'),
          ),
        );
      }
    }
  }

  static bool _isOnlyOwnerError(PostgrestException e) {
    final code = e.code ?? '';
    final msg = e.message.toLowerCase();
    return code == 'HO006' || msg.contains('only active owner');
  }

  @override
  Widget build(BuildContext context) {
    final householdAsync = ref.watch(householdByIdProvider(widget.householdId));
    final summaryAsync = ref.watch(
      householdSummaryProvider(widget.householdId),
    );
    final invitesAsync = ref.watch(
      householdInvitesProvider(widget.householdId),
    );
    final activityAsync = ref.watch(
      householdRecentActivityProvider(widget.householdId),
    );
    final tokens = context.tokens;

    // The header is ordinary scrollable content now (not a pinned
    // `AppBar`) — this is the Non-Sticky Headers change's reference case:
    // every branch below places the header as the first item of its own
    // scrollable, so it scrolls completely off-screen with the rest of the
    // page (dashboard tiles → recent activity → invites) and returns
    // naturally when scrolling back to the top. No sticky/collapsed
    // replacement.
    final header = AppScreenHeader(
      leading: const Center(child: AppBackButton()),
      title: householdAsync.when(
        data: (h) => h?.name ?? 'Home',
        loading: () => 'Loading...',
        error: (_, _) => 'Home',
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: AppSpacing.xs),
          // Same Telegram-frosted chrome as `AppCircleIconButton`, hand-built
          // here because a `PopupMenuButton` — not a plain callback — needs
          // to own the icon slot.
          child: DecoratedBox(
            decoration: const ShapeDecoration(
              shape: CircleBorder(
                side: BorderSide(
                  color: AppGlass.rimColor,
                  width: AppGlass.rimWidth,
                ),
              ),
              shadows: AppGlass.shadows,
            ),
            child: ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: AppGlass.blurSigma,
                  sigmaY: AppGlass.blurSigma,
                ),
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: AppGlass.fill),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            stops: const [0.0, 0.45],
                            colors: [
                              Colors.white.withValues(
                                alpha: AppGlass.highlightPeak,
                              ),
                              Colors.white.withValues(alpha: 0.0),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Material(
                      type: MaterialType.transparency,
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: PopupMenuButton<String>(
                          tooltip: 'Home actions',
                          icon: const Icon(Icons.more_vert_rounded),
                          onSelected: (value) {
                            if (value == 'leave') _leaveHousehold();
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'leave',
                              child: Text('Leave home'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: householdAsync.when(
          loading: () => ListView(
            children: [
              header,
              const AppSkeletonList(sectionCounts: {'': 4}, scrollable: false),
            ],
          ),
          error: (_, _) => ListView(
            children: [
              header,
              AppErrorState(
                message: 'Could not load home details. Please try again.',
                onRetry: () =>
                    ref.invalidate(householdByIdProvider(widget.householdId)),
              ),
            ],
          ),
          data: (household) {
            if (household == null) {
              return ListView(
                children: [
                  header,
                  const Center(child: Text('Home not found.')),
                ],
              );
            }
            final hid = widget.householdId;
            final summary = summaryAsync.asData?.value;

            return ListView(
              // Explicit padding (needed for the top offset) opts out of
              // automatic MediaQuery consumption, so the nav clearance has
              // to be re-applied by hand here — and only here.
              padding: EdgeInsets.only(
                top: AppSpacing.sm,
                bottom: context.shellBottomInset,
              ),
              children: [
                header,
                if (summaryAsync.hasError)
                  _InlineSectionError(
                    message: 'Could not load household counts.',
                    onRetry: () =>
                        ref.invalidate(householdSummaryProvider(hid)),
                  ),
                // ── Primary operational destinations ──────────────────────
                // Tasks + Shopping carry the heaviest visual weight (hero
                // number). This is the pair a member acts on most often.
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.base,
                    vertical: AppSpacing.sm,
                  ),
                  child: _TileRow(
                    children: [
                      _PrimaryTile(
                        icon: Icons.checklist_rounded,
                        accent: tokens.tasks,
                        label: 'Tasks',
                        count: summary?.incompleteTaskCount,
                        unitSingular: 'incomplete task',
                        unitPlural: 'incomplete tasks',
                        onTap: () => context.go('/homes/$hid/tasks'),
                      ),
                      _PrimaryTile(
                        icon: Icons.shopping_cart_rounded,
                        accent: tokens.shopping,
                        label: 'Shopping',
                        count: summary?.incompleteShoppingCount,
                        unitSingular: 'incomplete item',
                        unitPlural: 'incomplete items',
                        onTap: () => context.go('/homes/$hid/shopping'),
                      ),
                    ],
                  ),
                ),
                // ── Quieter, information/management destinations ─────────
                // Same tile family, deliberately lighter content: a status
                // line instead of a hero number, per the approved hierarchy.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.base,
                    0,
                    AppSpacing.base,
                    AppSpacing.sm,
                  ),
                  child: _TileRow(
                    children: [
                      _QuietTile(
                        icon: Icons.receipt_long_rounded,
                        accent: tokens.expenses,
                        label: 'Expenses',
                        status: summary == null
                            ? null
                            : _countLabel(summary.expenseCount, 'expense'),
                        onTap: () => context.go('/homes/$hid/expenses'),
                      ),
                      _QuietTile(
                        icon: Icons.people_rounded,
                        accent: tokens.members,
                        label: 'Members',
                        status: summary == null
                            ? null
                            : _countLabel(
                                summary.activeMemberCount,
                                'active member',
                              ),
                        onTap: () => context.go('/homes/$hid/members'),
                      ),
                    ],
                  ),
                ),
                // ── Statistics: a full-width destination row, not a tile ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.base,
                    0,
                    AppSpacing.base,
                    AppSpacing.sm,
                  ),
                  child: _StatisticsRow(
                    accent: tokens.statistics,
                    onTap: () => context.go('/homes/$hid/statistics'),
                  ),
                ),
                // ── Recent activity section ───────────────────────────────
                // Ranked above Invites: the daily feed outranks an occasional
                // owner action.
                const AppSectionHeader(label: 'Recent activity'),
                activityAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(AppSpacing.base),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (_, _) => _InlineSectionError(
                    message: 'Could not load activity.',
                    onRetry: () =>
                        ref.invalidate(householdRecentActivityProvider(hid)),
                  ),
                  data: (events) {
                    if (events.isEmpty) {
                      return const AppEmptyState(
                        icon: Icons.history_outlined,
                        title: 'No activity yet',
                        subtitle:
                            'Task completions, expenses, and member changes will appear here.',
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...events.map(
                          (e) => AppActivityRow(event: e, dense: true),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.base,
                              vertical: AppSpacing.xs,
                            ),
                            child: TextButton.icon(
                              onPressed: () => context.go(
                                '/homes/${widget.householdId}/activity',
                              ),
                              icon: const Icon(Icons.arrow_forward, size: 14),
                              iconAlignment: IconAlignment.end,
                              label: const Text('View all activity'),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                // ── Invites section ───────────────────────────────────────
                // Secondary to the daily feed above: an occasional owner action,
                // not something the user checks every visit.
                const AppSectionHeader(label: 'Invites'),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.base,
                    vertical: AppSpacing.xs,
                  ),
                  child: OutlinedButton(
                    onPressed: _isCreatingInvite ? null : _createInvite,
                    child: _isCreatingInvite
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Invite member'),
                  ),
                ),
                invitesAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(AppSpacing.base),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (_, _) => _InlineSectionError(
                    message: 'Could not load invites.',
                    onRetry: () =>
                        ref.invalidate(householdInvitesProvider(hid)),
                  ),
                  data: (invites) => Column(
                    children: invites
                        .map(
                          (i) => _InviteRow(
                            invite: i,
                            onRevoke: () => _revokeInvite(i.id),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _countLabel(int count, String noun) {
    if (count == 1) return '1 $noun';
    return '$count ${noun}s';
  }
}

// ---------------------------------------------------------------------------
// Responsive 2-up row — never a fixed-height GridView. Falls back to a single
// column when the available width (given the current text scale) can't hold
// two tiles without cramping — never a forced, breaking 2-column layout.
// ---------------------------------------------------------------------------

class _TileRow extends StatelessWidget {
  const _TileRow({required this.children});

  final List<Widget> children;

  // A tile narrower than this cramps its hero number/wrapped label — below
  // it, one full-width column reads better than two squeezed ones.
  static const double _minTileWidth = 140.0;

  // Above this text scale, tile content needs more room than any two-up
  // split of a normal phone width can give it, regardless of that width.
  static const double _maxTwoUpTextScale = 1.6;

  @override
  Widget build(BuildContext context) {
    // Measured at a real body-text size (14), not scale(1.0) — Android's
    // text-scale curve is nonlinear, so scaling a nominal "1.0" reference
    // does not track how much a real label actually grows.
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = (constraints.maxWidth - AppSpacing.sm) / 2;
        final twoUp =
            tileWidth >= _minTileWidth && textScale < _maxTwoUpTextScale;
        if (!twoUp) {
          // Fallback must fill the row, never shrink-wrap or center: each
          // tile takes the full width, one per line.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.sm),
                children[i],
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.sm),
              Expanded(child: children[i]),
            ],
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Primary tile (Tasks, Shopping) — heaviest visual weight: a hero number.
// ---------------------------------------------------------------------------

class _PrimaryTile extends StatelessWidget {
  const _PrimaryTile({
    required this.icon,
    required this.accent,
    required this.label,
    required this.count,
    required this.unitSingular,
    required this.unitPlural,
    required this.onTap,
  });

  final IconData icon;
  final FeatureAccent accent;
  final String label;
  final int? count;
  final String unitSingular;
  final String unitPlural;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final unit = count == 1 ? unitSingular : unitPlural;
    final semanticLabel = count == null ? label : '$label, $count $unit';

    return _TileSurface(
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIconChip(
            icon: icon,
            background: accent.container,
            foreground: accent.icon,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            label,
            style: theme.textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          if (count != null) ...[
            Text(
              '$count',
              style: theme.textTheme.heroNumber?.copyWith(fontSize: 28),
            ),
            Text(
              unit,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quiet tile (Expenses, Members) — icon + label + one plain status line.
// Deliberately no hero number: these are information/management
// destinations, not things to act on.
// ---------------------------------------------------------------------------

class _QuietTile extends StatelessWidget {
  const _QuietTile({
    required this.icon,
    required this.accent,
    required this.label,
    required this.status,
    required this.onTap,
  });

  final IconData icon;
  final FeatureAccent accent;
  final String label;
  final String? status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final semanticLabel = status == null ? label : '$label, $status';

    return _TileSurface(
      onTap: onTap,
      semanticLabel: semanticLabel,
      // Quieter than the primary tiles: a smaller icon chip, icon+label on
      // one row (per the approved board composition), and less vertical
      // padding — this pair should read as lighter weight, not just as a
      // primary tile with no hero number.
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AppIconChip(
                icon: icon,
                background: accent.container,
                foreground: accent.icon,
                size: 26,
                iconSize: 14,
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (status != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              status!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Statistics — a full-width destination row, not a tile. No invented metric:
// the subtitle is a stable, real description of what the screen offers.
// ---------------------------------------------------------------------------

class _StatisticsRow extends StatelessWidget {
  const _StatisticsRow({required this.accent, required this.onTap});

  final FeatureAccent accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    const subtitle = 'View household statistics';

    // Same soft-card family as the tiles above — white surface, shadow, no
    // hairline — so Statistics reads as belonging to the same layer, not a
    // separate, lower-effort row.
    return AppSoftCard(
      onTap: onTap,
      child: Semantics(
        label: 'Statistics, $subtitle',
        button: true,
        excludeSemantics: true,
        container: true,
        child: Row(
          children: [
            AppIconChip(
              icon: Icons.insights_rounded,
              background: accent.container,
              foreground: accent.icon,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Statistics', style: theme.textTheme.titleSmall),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared tile chrome: `AppSoftCard` (white surface, radius 24, soft shadow —
// no hairline), whole-tile tap target, one combined semantic announcement
// (never icon + label + metric separately).
// ---------------------------------------------------------------------------

class _TileSurface extends StatelessWidget {
  const _TileSurface({
    required this.onTap,
    required this.semanticLabel,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
  });

  final VoidCallback onTap;
  final String semanticLabel;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return AppSoftCard(
      onTap: onTap,
      padding: padding,
      child: Semantics(
        label: semanticLabel,
        button: true,
        excludeSemantics: true,
        container: true,
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// A compact, non-distorting error treatment for a dashboard subsection: one
// line of text + an inline Retry action. A full `AppErrorState` (icon + xl
// padding) is sized for a whole-screen failure, not a section embedded among
// otherwise-successful content — and one failed section must never hide the
// navigation the rest of the dashboard still offers.
// ---------------------------------------------------------------------------

class _InlineSectionError extends StatelessWidget {
  const _InlineSectionError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Invite row — lean single line: code, copy, revoke.
//
// Was a Card+ListTile per invite, whose border/elevation/default ListTile
// padding made "Invites" the tallest section on the dashboard for a single
// occasional owner action. A plain row keeps the code just as legible
// (still tabular, still monospaced-by-letter-spacing) without that overhead.
// ---------------------------------------------------------------------------

class _InviteRow extends StatelessWidget {
  const _InviteRow({required this.invite, required this.onRevoke});

  final HouseholdInvite invite;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              invite.code,
              style: theme.textTheme.titleSmall
                  ?.copyWith(letterSpacing: 2)
                  .tabular,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined, size: 18),
            tooltip: 'Copy invite code',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: invite.code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Invite code copied')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.block, size: 18),
            tooltip: 'Revoke invite',
            onPressed: onRevoke,
          ),
        ],
      ),
    );
  }
}
