import localUnitTest from './LocalUnit.test';
import learningFlowDataTest from './LearningFlowData.test';
import agentBridgeTest from './AgentBridge.test';
import exerciseFlowTest from './ExerciseFlow.test';
import apiDisplayFormatterTest from './ApiDisplayFormatter.test';

export default function testsuite() {
  localUnitTest();
  learningFlowDataTest();
  agentBridgeTest();
  exerciseFlowTest();
  apiDisplayFormatterTest();
}
