import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import 'i_garden_repository.dart';

class GardenRepository implements IGardenRepository {
  const GardenRepository(this._db);
  final Pool _db;

  @override
  Future<String?> memberRole(String gardenId, String userId) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT role FROM garden_members
        WHERE garden_id = @gardenId AND user_id = @userId
      '''),
      parameters: {'gardenId': gardenId, 'userId': userId},
    );
    return result.isEmpty ? null : result.first[0] as String;
  }

  @override
  Future<void> ensurePersonalGarden(String userId) =>
      _db.runTx((tx) => createPersonalGarden(tx, userId));

  @override
  Future<List<Map<String, dynamic>>> listForUser(String userId) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT g.id, g.name, g.personal, m.role, g.owner_user_id, u.email
        FROM garden_members m
        JOIN gardens g ON g.id = m.garden_id
        JOIN users u ON u.id = g.owner_user_id
        WHERE m.user_id = @userId
        ORDER BY (g.id = @userId) DESC, g.created_at, g.id
      '''),
      parameters: {'userId': userId},
    );
    return [
      for (final row in result)
        {
          'id': row[0] as String,
          'name': row[1] as String,
          'personal': row[2] as bool,
          'role': row[3] as String,
          'ownerUserId': row[4] as String,
          'ownerEmail': row[5] as String,
        }
    ];
  }

  @override
  Future<Map<String, dynamic>> create(String ownerUserId, String name) async {
    final id = const Uuid().v4();
    await _db.runTx((tx) async {
      await tx.execute(
        Sql.named('''
          INSERT INTO gardens (id, name, owner_user_id)
          VALUES (@id, @name, @owner)
        '''),
        parameters: {'id': id, 'name': name, 'owner': ownerUserId},
      );
      await tx.execute(
        Sql.named('''
          INSERT INTO garden_members (garden_id, user_id, role)
          VALUES (@id, @owner, 'owner')
        '''),
        parameters: {'id': id, 'owner': ownerUserId},
      );
    });
    return {'id': id, 'name': name, 'personal': false, 'role': 'owner'};
  }

  @override
  Future<void> rename(String gardenId, String name) async {
    await _db.execute(
      Sql.named('UPDATE gardens SET name = @name WHERE id = @id'),
      parameters: {'id': gardenId, 'name': name},
    );
  }

  @override
  Future<List<Map<String, dynamic>>> listMembers(String gardenId) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT m.user_id, u.email, m.role, m.added_at
        FROM garden_members m
        JOIN users u ON u.id = m.user_id
        WHERE m.garden_id = @gardenId
        ORDER BY (m.role = 'owner') DESC, m.added_at, u.email
      '''),
      parameters: {'gardenId': gardenId},
    );
    return [
      for (final row in result)
        {
          'userId': row[0] as String,
          'email': row[1] as String,
          'role': row[2] as String,
          'addedAt': (row[3] as DateTime).toIso8601String(),
        }
    ];
  }

  @override
  Future<bool> addMember(String gardenId, String userId) async {
    final result = await _db.execute(
      Sql.named('''
        INSERT INTO garden_members (garden_id, user_id, role)
        VALUES (@gardenId, @userId, 'member')
        ON CONFLICT DO NOTHING
      '''),
      parameters: {'gardenId': gardenId, 'userId': userId},
    );
    return result.affectedRows > 0;
  }

  @override
  Future<bool> removeMember(String gardenId, String userId) async {
    final result = await _db.execute(
      Sql.named('''
        DELETE FROM garden_members
        WHERE garden_id = @gardenId AND user_id = @userId AND role = 'member'
      '''),
      parameters: {'gardenId': gardenId, 'userId': userId},
    );
    return result.affectedRows > 0;
  }
}

/// Creates [userId]'s personal garden and owner membership if missing. Shared
/// with AuthRepository so a new account gets it in the same transaction.
Future<void> createPersonalGarden(Session tx, String userId) async {
  await tx.execute(
    Sql.named('''
      INSERT INTO gardens (id, owner_user_id, personal)
      VALUES (@id, @id, TRUE)
      ON CONFLICT (id) DO NOTHING
    '''),
    parameters: {'id': userId},
  );
  await tx.execute(
    Sql.named('''
      INSERT INTO garden_members (garden_id, user_id, role)
      SELECT id, owner_user_id, 'owner' FROM gardens
      WHERE id = @id AND personal
      ON CONFLICT DO NOTHING
    '''),
    parameters: {'id': userId},
  );
}
