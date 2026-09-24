import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** Persists the minimal state required to resume the fixed offline demo. */
export class FixtureDemoStateStore {
  private static readonly STORE_NAME: string = 'fixture_demo_state';
  private static readonly KEY_EXERCISE_SUBMITTED: string = 'exercise_submitted';
  private static readonly KEY_MASTERY_SCORE: string = 'mastery_score';
  /** 与后端演示基线一致：初始掌握度 42。 */
  private static readonly INITIAL_MASTERY_SCORE: number = 42;
  private static context: common.UIAbilityContext | null = null;
  private static exerciseSubmitted: boolean = false;
  private static masteryScore: number = FixtureDemoStateStore.INITIAL_MASTERY_SCORE;

  static initialize(context: common.UIAbilityContext): boolean {
    FixtureDemoStateStore.context = context;
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, {
        name: FixtureDemoStateStore.STORE_NAME
      });
      FixtureDemoStateStore.exerciseSubmitted =
        store.getSync(FixtureDemoStateStore.KEY_EXERCISE_SUBMITTED, false) as boolean;
      FixtureDemoStateStore.masteryScore =
        store.getSync(FixtureDemoStateStore.KEY_MASTERY_SCORE,
          FixtureDemoStateStore.INITIAL_MASTERY_SCORE) as number;
      return true;
    } catch (error) {
      FixtureDemoStateStore.exerciseSubmitted = false;
      FixtureDemoStateStore.masteryScore = FixtureDemoStateStore.INITIAL_MASTERY_SCORE;
      return false;
    }
  }

  static isExerciseSubmitted(): boolean {
    return FixtureDemoStateStore.exerciseSubmitted;
  }

  /** 离线 Fixture 的掌握度由本模块持有，保证"改答案 → 分数变 → 掌握度变"在离线模式同样成立。 */
  static getMasteryScore(): number {
    return FixtureDemoStateStore.masteryScore;
  }

  static setMasteryScore(value: number): boolean {
    FixtureDemoStateStore.masteryScore = Math.max(0, Math.min(100, value));
    FixtureDemoStateStore.exerciseSubmitted = true;
    return FixtureDemoStateStore.persist();
  }

  static markExerciseSubmitted(): boolean {
    FixtureDemoStateStore.exerciseSubmitted = true;
    return FixtureDemoStateStore.persist();
  }

  static reset(): boolean {
    FixtureDemoStateStore.exerciseSubmitted = false;
    FixtureDemoStateStore.masteryScore = FixtureDemoStateStore.INITIAL_MASTERY_SCORE;
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
      store.putSync(FixtureDemoStateStore.KEY_MASTERY_SCORE,
        FixtureDemoStateStore.masteryScore);
      store.flushSync();
      return true;
    } catch (error) {
      return false;
    }
  }
}
