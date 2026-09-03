import { AgentApiClient } from '../api/AgentApiClient';
import { ExerciseSetResponse, ExerciseSubmission, ExerciseSubmissionResult } from '../api/ApiModels';
import { ClientCache } from '../cache/ClientCache';

/**
 * Prepares the exercise flow for the page. Scores and mastery are always
 * returned by the API/fixture; this class does not calculate them.
 */
export class ExerciseViewModel {
  async load(setId: string): Promise<ExerciseSetResponse | null> {
    const cached: ExerciseSetResponse | null = ClientCache.getExerciseSet();
    if (cached !== null && cached.setId === setId) {
      return cached;
    }
    const result = await AgentApiClient.getExerciseSet(setId);
    if (result.ok) {
      ClientCache.cacheExerciseSet(result.data);
      return result.data;
    }
    return null;
  }

  async submit(setId: string, submission: ExerciseSubmission): Promise<ExerciseSubmissionResult | null> {
    const result = await AgentApiClient.submitExercise(setId, submission);
    if (result.ok) {
      ClientCache.cacheAssessment(result.data);
      if (result.data.planDiff !== undefined) {
        ClientCache.cachePlanDiff(result.data.planDiff);
      }
      if (result.data.plan !== undefined) {
        ClientCache.cacheCurrentPlan(result.data.plan);
      }
      ClientCache.invalidateProfile();
      return result.data;
    }
    return null;
  }
}
