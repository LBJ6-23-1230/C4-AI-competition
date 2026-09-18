import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** Persists the minimal state required to resume the fixed offline demo. */
export class FixtureDemoStateStore {
  private static readonly STORE_NAME: string = 'fixture_demo_state';
  private static readonly KEY_EXERCISE_SUBMITTED: string = 'exercise_submitted';
  private static readonly KEY_SCORE: string = 'score';
  private static readonly KEY_MASTERY: string = 'mastery';
  private static context: common.UIAbilityContext | null = null;
  private static exerciseSubmitted: boolean = false;
  private static score: number = 0;
  private static mastery: number = 42;

  static initialize(context: common.UIAbilityContext): boolean {
    FixtureDemoStateStore.context = context;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: FixtureDemoStateStore.STORE_NAME
      });
      FixtureDemoStateStore.exerciseSubmitted =
        store.getSync(FixtureDemoStateStore.KEY_EXERCISE_SUBMITTED, false) as boolean;
      FixtureDemoStateStore.score = store.getSync(FixtureDemoStateStore.KEY_SCORE, 0) as number;
      FixtureDemoStateStore.mastery = store.getSync(FixtureDemoStateStore.KEY_MASTERY, 42) as number;
      return true;
    } catch (error) {
      FixtureDemoStateStore.exerciseSubmitted = false;
      FixtureDemoStateStore.score = 0;
      FixtureDemoStateStore.mastery = 42;
      return false;
    }
  }

  static isExerciseSubmitted(): boolean {
    return FixtureDemoStateStore.exerciseSubmitted;
  }

  static markExerciseSubmitted(score: number, mastery: number): boolean {
    FixtureDemoStateStore.exerciseSubmitted = true;
    FixtureDemoStateStore.score = score;
    FixtureDemoStateStore.mastery = mastery;
    return FixtureDemoStateStore.persist();
  }

  static getScore(): number {
    return FixtureDemoStateStore.score;
  }

  static getMasteryScore(): number {
    return FixtureDemoStateStore.mastery;
  }

  static reset(): boolean {
    FixtureDemoStateStore.exerciseSubmitted = false;
    FixtureDemoStateStore.score = 0;
    FixtureDemoStateStore.mastery = 42;
    return FixtureDemoStateStore.persist();
  }

  private static persist(): boolean {
    if (FixtureDemoStateStore.context === null) {
      return true;
    }
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(FixtureDemoStateStore.context, {
        name: FixtureDemoStateStore.STORE_NAME
      });
      store.putSync(FixtureDemoStateStore.KEY_EXERCISE_SUBMITTED,
        FixtureDemoStateStore.exerciseSubmitted);
      store.putSync(FixtureDemoStateStore.KEY_SCORE, FixtureDemoStateStore.score);
      store.putSync(FixtureDemoStateStore.KEY_MASTERY, FixtureDemoStateStore.mastery);
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
