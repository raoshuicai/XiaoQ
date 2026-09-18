import chatStreamEngineTest from './ChatStreamEngine.test';
import chatServiceTest from './ChatService.test';

export default function testsuite() {
  chatStreamEngineTest();
  chatServiceTest();
}
