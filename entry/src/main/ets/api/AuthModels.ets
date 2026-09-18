export type AuthSource = 'guest' | 'local';

export interface AuthSession {
  userId: string;
  nickname: string;
  source: AuthSource;
}

export class AuthRules {
  static readonly MIN_NICKNAME_LENGTH: number = 2;
  static readonly MAX_NICKNAME_LENGTH: number = 16;

  static nicknameError(nickname: string): string {
    const length: number = nickname.trim().length;
    if (length < AuthRules.MIN_NICKNAME_LENGTH) return '昵称至少需要 2 个字符。';
    if (length > AuthRules.MAX_NICKNAME_LENGTH) return '昵称不能超过 16 个字符。';
    return '';
  }
}
