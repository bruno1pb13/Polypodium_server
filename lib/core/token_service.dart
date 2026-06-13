import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

class TokenExpiredException implements Exception {
  const TokenExpiredException();
}

class InvalidTokenException implements Exception {
  const InvalidTokenException(this.message);
  final String message;
}

abstract interface class ITokenService {
  String sign(String userId, String deviceId);
  ({String userId, String deviceId}) verify(String token);
}

class JwtTokenService implements ITokenService {
  const JwtTokenService(this._secret);
  final String _secret;

  @override
  String sign(String userId, String deviceId) {
    final jwt = JWT({'deviceId': deviceId}, subject: userId);
    return jwt.sign(SecretKey(_secret), expiresIn: const Duration(days: 30));
  }

  @override
  ({String userId, String deviceId}) verify(String token) {
    try {
      final jwt = JWT.verify(token, SecretKey(_secret));
      final payload = jwt.payload as Map<String, dynamic>;
      final userId = jwt.subject;
      final deviceId = payload['deviceId'] as String?;
      if (userId == null || deviceId == null) {
        throw const InvalidTokenException('malformed token claims');
      }
      return (userId: userId, deviceId: deviceId);
    } on JWTExpiredException {
      throw const TokenExpiredException();
    } on JWTException catch (e) {
      throw InvalidTokenException('invalid token: ${e.message}');
    }
  }
}
