// The bench's name for the tab's session. The value -- and every rule about it -- moved to pageSession.js when the
// plan board needed the same thing for its own locks (082); this is the name the bench's code was written against,
// and renaming it in ten call sites would have been churn for nothing.
export { pageSession as benchSession } from './pageSession'
