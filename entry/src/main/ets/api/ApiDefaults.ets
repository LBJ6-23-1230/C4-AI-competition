/** Shared frontend defaults. Keep protocol, environment and demo identity in one place. */
export class ApiDefaults {
  static readonly CONTRACT_VERSION: string = 'api-contract-v0.3';
  static readonly EMULATOR_BASE_URL: string = 'http://10.0.2.2:5000';
  static readonly DEFAULT_TIMEOUT_MS: number = 8000;
  static readonly DEMO_USER_ID: string = 'demo-user';
}
