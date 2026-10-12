/// What an MCP token grants once resolved: one garden, acting as the member
/// who created the token.
class McpGrant {
  const McpGrant({
    required this.tokenId,
    required this.gardenId,
    required this.gardenName,
    required this.userId,
    required this.canWrite,
  });

  final String tokenId;
  final String gardenId;
  final String gardenName;
  final String userId;
  final bool canWrite;

  /// Device id recorded as the writer of rows this token changes, so LWW
  /// ties and "last edited by" stay attributable to the connection.
  String get deviceId => 'mcp-$tokenId';
}

/// Long-lived access tokens for the MCP endpoint, one garden each.
abstract interface class IMcpTokenRepository {
  /// Creates a token for [userId] in [gardenId] and returns its row plus the
  /// secret (`token`), which is never retrievable again.
  Future<Map<String, dynamic>> create(
    String gardenId,
    String userId, {
    required String name,
    required bool canWrite,
  });

  /// Tokens in [gardenId]; only [userId]'s own unless [userId] is null.
  Future<List<Map<String, dynamic>>> list(String gardenId, {String? userId});

  /// How many tokens [userId] holds in [gardenId].
  Future<int> countFor(String gardenId, String userId);

  /// The owning user of token [tokenId] in [gardenId], or null.
  Future<String?> ownerOf(String gardenId, String tokenId);

  Future<bool> delete(String gardenId, String tokenId);

  /// Resolves a presented secret. Null when unknown, or when its account is
  /// disabled or no longer a member of the garden -- a token never outlives
  /// the access of the member who created it.
  Future<McpGrant?> resolve(String secret);
}
