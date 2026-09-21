import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/homes/data/household_dashboard_repository.dart';
import 'package:household_os/features/homes/data/household_repository.dart';
import 'package:household_os/features/homes/data/household_stats_repository.dart';
import 'package:household_os/features/homes/domain/household.dart';
import 'package:household_os/features/homes/domain/household_event.dart';
import 'package:household_os/features/homes/domain/household_invite.dart';
import 'package:household_os/features/homes/domain/household_member_info.dart';
import 'package:household_os/features/homes/domain/household_summary.dart';
import 'package:household_os/features/homes/domain/household_stats.dart';
import 'package:household_os/features/homes/domain/task_rotation_suggestion.dart';

class HomesNotifier extends AsyncNotifier<List<Household>> {
  HouseholdRepository get _repo => HouseholdRepository(supabaseClient);

  @override
  Future<List<Household>> build() => _repo.fetchActiveHouseholds();

  Future<void> createHousehold(String name) async {
    final household = await _repo.createHousehold(name);
    final current = switch (state) {
      AsyncData(:final value) => value,
      _ => <Household>[],
    };
    state = AsyncData([...current, household]);
  }

  Future<Household> joinHousehold(String inviteCode) async {
    final household = await _repo.joinHousehold(inviteCode);
    final current = switch (state) {
      AsyncData(:final value) => value,
      _ => <Household>[],
    };
    if (!current.any((h) => h.id == household.id)) {
      state = AsyncData([...current, household]);
    }
    return household;
  }

  Future<void> leaveHousehold(String householdId) async {
    await _repo.leaveHousehold(householdId);
    final current = switch (state) {
      AsyncData(:final value) => value,
      _ => <Household>[],
    };
    state = AsyncData(current.where((h) => h.id != householdId).toList());
  }
}

final homesProvider = AsyncNotifierProvider<HomesNotifier, List<Household>>(
  HomesNotifier.new,
);

final householdByIdProvider = FutureProvider.family<Household?, String>((
  ref,
  id,
) async {
  return HouseholdRepository(supabaseClient).fetchHousehold(id);
});

final householdInvitesProvider =
    FutureProvider.family<List<HouseholdInvite>, String>((
      ref,
      householdId,
    ) async {
      return HouseholdRepository(
        supabaseClient,
      ).fetchActiveInvites(householdId);
    });

final householdSummaryProvider =
    FutureProvider.family<HouseholdSummary, String>((ref, householdId) {
      return HouseholdDashboardRepository(
        supabaseClient,
      ).fetchSummary(householdId);
    });

final householdMembersProvider =
    FutureProvider.family<List<HouseholdMemberInfo>, String>((
      ref,
      householdId,
    ) {
      return HouseholdDashboardRepository(
        supabaseClient,
      ).fetchMembers(householdId);
    });

final householdRecentActivityProvider =
    FutureProvider.family<List<HouseholdEvent>, String>((ref, householdId) {
      return HouseholdDashboardRepository(
        supabaseClient,
      ).fetchRecentActivity(householdId);
    });

final householdAllActivityProvider =
    FutureProvider.family<List<HouseholdEvent>, String>((ref, householdId) {
      return HouseholdDashboardRepository(
        supabaseClient,
      ).fetchActivity(householdId);
    });

final householdStatsProvider =
    FutureProvider.family<HouseholdStats, HouseholdStatsRequest>((
      ref,
      request,
    ) {
      return HouseholdStatsRepository(
        supabaseClient,
      ).fetchStats(householdId: request.householdId, period: request.period);
    });

final taskRotationSuggestionsProvider =
    FutureProvider.family<List<TaskRotationSuggestion>, String>((
      ref,
      householdId,
    ) {
      return HouseholdStatsRepository(
        supabaseClient,
      ).fetchRotationSuggestions(householdId: householdId);
    });
