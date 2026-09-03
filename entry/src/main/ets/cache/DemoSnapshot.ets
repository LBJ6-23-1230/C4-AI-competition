import { ClientCache } from './ClientCache';

/**
 * Fixed identifiers for the contest demonstration only.
 * It is not an offline business engine: score, mastery and replan results
 * must still come from the API fixture or backend.
 */
export class DemoSnapshot {
  static readonly USER_ID: string = 'demo-user';
  static readonly EXERCISE_SET_ID: string = 'set-demo-binary-tree-001';
  static readonly INITIAL_PLAN_ID: string = 'plan-demo-001';

  static clearAfterReset(): void {
    ClientCache.clearDemoData();
  }
}
