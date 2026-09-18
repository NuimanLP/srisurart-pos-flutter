// Client repository for review items requiring owner attention.
// Defined in docs/Backend_design/09_PHASE2_LANES.md §3, §6 and 08_PHASE2_SPEC.md §14.

import '../../core/network/api_client.dart';
import '../../core/utils/ids.dart';
import '../../domain/models/review_item.dart';

class ReviewItemsRepository {
  final ApiClient _apiClient;

  ReviewItemsRepository(this._apiClient);

  Future<List<ReviewItem>> listPending({int page = 1, int limit = 50}) async {
    final res = await _apiClient.getPaginated(
      '/api/v1/review-items',
      queryParameters: {
        'status': 'pending',
        'page': page.toString(),
        'limit': limit.toString(),
      },
    );

    return res.data
        .map((e) => ReviewItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> markReviewed(String id) async {
    await _apiClient.post(
      '/api/v1/review-items/$id/reviewed',
      headers: {
        'Idempotency-Key': newId('idem_rev_'),
      },
    );
  }
}
