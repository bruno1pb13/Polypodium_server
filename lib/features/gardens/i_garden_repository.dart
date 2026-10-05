/// Gardens (jardins) scope all synced data and photos. Every account owns a
/// personal garden whose id equals the account id; any other garden is
/// created explicitly and shared with other accounts on the same server.
abstract interface class IGardenRepository {
  /// The role ('owner' | 'member') of [userId] in [gardenId], or null when
  /// the garden doesn't exist or the user isn't a member.
  Future<String?> memberRole(String gardenId, String userId);

  /// Creates [userId]'s personal garden (and its owner membership) when
  /// missing.
  Future<void> ensurePersonalGarden(String userId);

  /// Gardens [userId] belongs to, personal first, each with the caller's
  /// role and the owner's e-mail.
  Future<List<Map<String, dynamic>>> listForUser(String userId);

  Future<Map<String, dynamic>> create(String ownerUserId, String name);
  Future<void> rename(String gardenId, String name);
  Future<List<Map<String, dynamic>>> listMembers(String gardenId);

  /// Adds [userId] as a member; false when they already belong to it.
  Future<bool> addMember(String gardenId, String userId);

  /// Removes [userId] from the garden; false when they weren't a member.
  Future<bool> removeMember(String gardenId, String userId);
}
