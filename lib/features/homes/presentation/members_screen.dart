import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/app/theme/app_shell_metrics.dart';
import 'package:household_os/app/theme/app_theme.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/core/theme/app_spacing.dart';
import 'package:household_os/core/widgets/app_back_button.dart';
import 'package:household_os/core/widgets/app_empty_state.dart';
import 'package:household_os/core/widgets/app_error_state.dart';
import 'package:household_os/core/widgets/app_screen_header.dart';
import 'package:household_os/core/widgets/app_skeleton_list.dart';
import 'package:household_os/core/widgets/app_soft_card.dart';
import 'package:household_os/features/homes/data/household_repository.dart';
import 'package:household_os/features/homes/domain/household_member_info.dart';
import 'package:household_os/features/homes/presentation/homes_provider.dart';

class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({
    super.key,
    required this.householdId,
    this.currentUserIdOverride,
    this.removeMemberOverride,
    this.transferOwnershipOverride,
  });

  final String householdId;
  final String? currentUserIdOverride;
  final Future<void> Function(String householdId, String userId)?
  removeMemberOverride;
  final Future<void> Function(String householdId, String newOwnerId)?
  transferOwnershipOverride;

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  final Set<String> _submittingMemberActions = <String>{};

  String? get _currentUserId =>
      widget.currentUserIdOverride ?? supabaseClient.auth.currentUser?.id;

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(
      householdMembersProvider(widget.householdId),
    );
    final currentUserId = _currentUserId;
    // The header is ordinary scrollable content now (not a pinned `AppBar`)
    // — every branch below places it as the first item of its own
    // scrollable, so it scrolls away with the page and returns naturally
    // at the top.
    const header = AppScreenHeader(
      leading: Center(child: AppBackButton()),
      title: 'Members',
    );

    return Scaffold(
      body: membersAsync.when(
        loading: () => SafeArea(
          bottom: false,
          child: ListView(
            children: const [
              header,
              AppSkeletonList(sectionCounts: {'': 5}, scrollable: false),
            ],
          ),
        ),
        error: (_, _) => SafeArea(
          bottom: false,
          child: ListView(
            children: [
              header,
              AppErrorState(
                message: 'Could not load members. Please try again.',
                onRetry: () => ref.invalidate(
                  householdMembersProvider(widget.householdId),
                ),
              ),
            ],
          ),
        ),
        data: (members) {
          if (members.isEmpty) {
            return SafeArea(
              bottom: false,
              child: ListView(
                children: const [
                  header,
                  AppEmptyState(title: 'No members found.'),
                ],
              ),
            );
          }

          final currentMember = currentUserId == null
              ? null
              : members
                    .where((member) => member.userId == currentUserId)
                    .firstOrNull;
          final canManageMembers = currentMember?.isOwner ?? false;

          return SafeArea(
            bottom: false,
            child: ListView.separated(
              padding: EdgeInsets.only(
                left: AppSpacing.base,
                right: AppSpacing.base,
                top: AppSpacing.sm,
                bottom: context.shellBottomInset + AppSpacing.base,
              ),
              // +1 for the header, kept in the same lazy builder-backed
              // list as the (potentially long) member rows.
              itemCount: members.length + 1,
              // Each row is its own soft card (`docs/new_design` family) — a
              // gap between them, not a shared hairline.
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (ctx, i) {
                if (i == 0) return header;
                final member = members[i - 1];
                final isCurrentUser = member.userId == currentUserId;
                return _MemberRow(
                  member: member,
                  isCurrentUser: isCurrentUser,
                  canManage:
                      canManageMembers && !isCurrentUser && !member.isOwner,
                  isSubmitting: _submittingMemberActions.contains(
                    member.userId,
                  ),
                  onTransferOwnership: () => _confirmTransferOwnership(member),
                  onRemove: () => _confirmRemoveMember(member),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmTransferOwnership(HouseholdMemberInfo member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Transfer ownership to ${member.displayName}?'),
        content: const Text(
          'They become the household owner. You become a regular member.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Transfer ownership'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runMemberAction(
      member.userId,
      () async {
        final transferOwnership = widget.transferOwnershipOverride;
        if (transferOwnership != null) {
          await transferOwnership(widget.householdId, member.userId);
        } else {
          await HouseholdRepository(supabaseClient).transferOwnership(
            householdId: widget.householdId,
            newOwnerId: member.userId,
          );
        }
      },
      successMessage: 'Ownership transferred.',
      errorMessage: 'Could not transfer ownership. Please try again.',
    );
  }

  Future<void> _confirmRemoveMember(HouseholdMemberInfo member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${member.displayName} from this home?'),
        content: const Text(
          'They lose access. Their historical activity remains, and they can join again later with an invite.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove from home'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runMemberAction(
      member.userId,
      () async {
        final removeMember = widget.removeMemberOverride;
        if (removeMember != null) {
          await removeMember(widget.householdId, member.userId);
        } else {
          await HouseholdRepository(supabaseClient).removeMember(
            householdId: widget.householdId,
            userId: member.userId,
          );
        }
      },
      successMessage: '${member.displayName} was removed.',
      errorMessage: 'Could not remove member. Please try again.',
    );
  }

  Future<void> _runMemberAction(
    String userId,
    Future<void> Function() action, {
    required String successMessage,
    required String errorMessage,
  }) async {
    if (_submittingMemberActions.contains(userId)) return;
    setState(() => _submittingMemberActions.add(userId));
    try {
      await action();
      if (!mounted) return;
      _refreshHouseholdMembers();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (_) {
      if (!mounted) return;
      _refreshHouseholdMembers();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage)));
    } finally {
      if (mounted) {
        setState(() => _submittingMemberActions.remove(userId));
      }
    }
  }

  void _refreshHouseholdMembers() {
    ref.invalidate(householdMembersProvider(widget.householdId));
    ref.invalidate(householdSummaryProvider(widget.householdId));
  }
}

// ---------------------------------------------------------------------------
// Member row — bare, hairline-separated (via the list's separator), no Card.
// Role/You state is plain text hierarchy, never a colored chip. Public ID is
// shown only on the current user's own row (privacy rule) — other members'
// IDs stay off the main scanning list entirely.
// ---------------------------------------------------------------------------

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isCurrentUser,
    required this.canManage,
    required this.isSubmitting,
    required this.onTransferOwnership,
    required this.onRemove,
  });

  final HouseholdMemberInfo member;
  final bool isCurrentUser;
  final bool canManage;
  final bool isSubmitting;
  final VoidCallback onTransferOwnership;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final metaParts = [if (member.isOwner) 'Owner', if (isCurrentUser) 'You'];
    final metaLine = metaParts.join(' · ');

    return AppSoftCard(
      child: Row(
        children: [
          // The initial letter inside the avatar would otherwise be
          // announced as its own bit of text ("M") right next to the
          // member's full name — redundant, not meaningful on its own. Kept
          // as a plain avatar, not an `AppIconChip` — a person is not a
          // feature (`docs/new_design` Members guidance).
          ExcludeSemantics(
            child: CircleAvatar(
              backgroundColor: colorScheme.primaryContainer,
              child: Text(
                member.displayName.isNotEmpty
                    ? member.displayName[0].toUpperCase()
                    : '?',
                style: TextStyle(color: colorScheme.onPrimaryContainer),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // MergeSemantics combines the name, role/You state, and (on the
          // current user's own row) the public ID into one coherent
          // announcement, rather than three separate fragments.
          Expanded(
            child: MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    member.displayName,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (metaLine.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        metaLine,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (isCurrentUser)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        member.publicId,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant)
                            .tabular,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (isSubmitting)
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (canManage)
            PopupMenuButton<String>(
              tooltip: 'Member actions',
              icon: Icon(
                Icons.more_vert_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
              onSelected: (value) {
                if (value == 'transfer') onTransferOwnership();
                if (value == 'remove') onRemove();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'transfer',
                  child: Text('Transfer ownership'),
                ),
                PopupMenuItem(value: 'remove', child: Text('Remove from home')),
              ],
            ),
        ],
      ),
    );
  }
}
