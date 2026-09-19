import localUnitTest from './LocalUnit.test';
import learningFlowDataTest from './LearningFlowData.test';
import agentBridgeTest from './AgentBridge.test';
import exerciseFlowTest from './ExerciseFlow.test';
import apiDisplayFormatterTest from './ApiDisplayFormatter.test';
import wrongQuestionPlanTest from './WrongQuestionPlan.test';
import focusLogicTest from './FocusLogic.test';
import partnerFlowTest from './PartnerFlow.test';
import apiResponseValidatorTest from './ApiResponseValidator.test';
import proactiveContextTest from './ProactiveContext.test';
import learningCardTest from './LearningCard.test';
import workflowViewModelTest from './WorkflowViewModel.test';

export default function testsuite() {
  localUnitTest();
  learningFlowDataTest();
  agentBridgeTest();
  exerciseFlowTest();
  apiDisplayFormatterTest();
  wrongQuestionPlanTest();
  focusLogicTest();
  partnerFlowTest();
  apiResponseValidatorTest();
  proactiveContextTest();
  learningCardTest();
  workflowViewModelTest();
}
