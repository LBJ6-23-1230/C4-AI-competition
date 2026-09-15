import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** Persists the minimal state required to resume the fixed offline demo. */
export class FixtureDemoStateStore {
  private static readonly STORE_NAME: string = 'fixture_demo_state';
  private static readonly KEY_EXERCISE_SUBMITTED: string = 'exercise_submitted';
  private static context: common.UIAbilityContext | null = null;
  private static exerciseSubmitted: boolean = false;

  static initialize(context: common.UIAbilityContext): boolean {
    FixtureDemoStateStore.context = context;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: FixtureDemoStateStore.STORE_NAME
      });
      FixtureDemoStateStore.exerciseSubmitted =
        store.getSync(FixtureDemoStateStore.KEY_EXERCISE_SUBMITTED, false) as boolean;
      return true;
    } catch (error) {
      FixtureDemoStateStore.exerciseSubmitted = false;
      return false;
    }
  }

  static isExerciseSubmitted(): boolean {
    return FixtureDemoStateStore.exerciseSubmitted;
  }

  static markExerciseSubmitted(): boolean {
    FixtureDemoStateStore.exerciseSubmitted = true;
    return FixtureDemoStateStore.persist();
  }

  static reset(): boolean {
    FixtureDemoStateStore.exerciseSubmitted = false;
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
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
