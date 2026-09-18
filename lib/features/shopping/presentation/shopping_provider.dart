import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:household_os/core/services/supabase_service.dart';
import 'package:household_os/features/shopping/data/shopping_repository.dart';
import 'package:household_os/features/shopping/domain/shopping_item.dart';

/// Streams shopping items for [householdId] via Supabase Realtime.
/// autoDispose cancels the subscription when the screen is left.
final shoppingItemsProvider = StreamProvider.autoDispose
    .family<List<ShoppingItem>, String>(
      (ref, householdId) =>
          ShoppingRepository(supabaseClient).watchItems(householdId),
    );
