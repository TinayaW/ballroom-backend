import ballerina/io;
import ballerinax/rabbitmq;
import ballerina/file;
import wso2/data_model;
import ballerinax/mysql;
import ballerinax/mysql.driver as _; // This bundles the driver to the project so that you don't need to bundle it via the `Ballerina.toml` file.
import ballerina/regex;
import executor_service.utils as utils;

configurable string USER = ?;
configurable string PASSWORD = ?;
configurable string HOST = ?;
configurable int PORT = ?;
configurable string DATABASE = ?;

// The consumer service listens to the "RequestQueue" queue.
listener rabbitmq:Listener channelListener= new(rabbitmq:DEFAULT_HOST, rabbitmq:DEFAULT_PORT);
   
@rabbitmq:ServiceConfig {
    queueName: data_model:QUEUE_NAME
}
service rabbitmq:Service on channelListener {

    private final rabbitmq:Client rabbitmqClient;

    function init() returns error? {
        // Initiate the RabbitMQ client at the start of the service. This will be used
        // throughout the lifetime of the service.
        self.rabbitmqClient = check new (rabbitmq:DEFAULT_HOST, rabbitmq:DEFAULT_PORT);
    }

    remote function onMessage(data_model:SubmissionMessage submissionEvent) returns error? {

        // need to evaluate the score
        data_model:ScoredSubmissionMessage scoredSubMsg = check handleEvent(submissionEvent);

        check self.rabbitmqClient->publishMessage({
            content: scoredSubMsg,
            routingKey: data_model:EXEC_TO_SCORE_QUEUE_NAME
        });
    }
}

function handleEvent(data_model:SubmissionMessage submissionEvent) returns error|data_model:ScoredSubmissionMessage {
    string basePath = "../storedFiles/";
    string fileNameWithExtension = submissionEvent.fileName + submissionEvent.fileExtension;
    
    // get the file
    string|error storedLocation = getAndStoreFile(submissionEvent.fileName, submissionEvent.fileExtension, submissionEvent.submissionId);

    // unzip the submissionZip
    string[] unzipArguments = ["unzip " + basePath + fileNameWithExtension + " -d " + basePath + submissionEvent.fileName + "/"];

    string[]|error executeCommandResult1 = executeCommand(unzipArguments);

    // replace the test cases
    check file:remove(basePath + submissionEvent.fileName + "/tests", file:RECURSIVE);

    // get the test case file and store in the same location
    () _ = check getAndStoreTestCase(submissionEvent.challengeId, check storedLocation);

    string[] testUnzipArguments = ["unzip " + basePath + submissionEvent.fileName + "/testsZip" + " -d " + basePath + submissionEvent.fileName + "/tests/"];
    string[]|error executeCommandResult2 = executeCommand(testUnzipArguments);

    string[] testCommand = ["cd " + check storedLocation +  " && bal test"];

    string[] executeCommandResult = check executeCommand(testCommand);

    float score = check calculateScore(executeCommandResult);

    data_model:ScoredSubmissionMessage scoredSubMsg = {subMsg: submissionEvent, score: score};

    return scoredSubMsg;

}

function calculateScore(string[] executeCommandResult) returns float|error {

    string balCommandOutput = "";
    float score = 0.0;
    foreach string line in executeCommandResult {
        balCommandOutput += "\n" + line;
    }

    // calculate scores
    int passingTests = 0;
    int totalTests = 0;
    string[] reversedConsoleContent = executeCommandResult.reverse();

    boolean processPassing = false;
    boolean processFailing = false;
    boolean processSkipped = false;
    foreach string line in reversedConsoleContent {
        if (processPassing && processFailing && processSkipped) {
            break;
        } else {
            if (string:includes(line, "passing") && !processPassing) {
            passingTests = check int:fromString(regex:split(string:trim(line), " ")[0]);
            totalTests += check int:fromString(regex:split(string:trim(line), " ")[0]);
            processPassing = true;
        }
        if (string:includes(line, "failing") && !processFailing) {
            totalTests += check int:fromString(regex:split(string:trim(line), " ")[0]);
            processFailing = true;
        }
        if (string:includes(line, "skipped") && !processSkipped) {
            totalTests += check int:fromString(regex:split(string:trim(line), " ")[0]);
            processSkipped = true;
        }
        }
    }
    if totalTests > 0 {
        score = (10.0 * <float>passingTests) / <float>totalTests;
    }
    return score;
}

function getTestDirPath(string challengeId) returns string {
    // hardcoding a value for now (ideally should be generated using the challenge id)
    return "./challengetests/tests/";
}

function getAndStoreFile(string fileName, string fileExtension, string submissionId) returns string|error{
    string basePath = "../storedFiles";
    string fileLocation = fileName + fileExtension;
    // should get the file from the given location and store it somewhere, then return where you stored it
    boolean dirExists = check file:test(basePath, file:EXISTS);
    if(!dirExists){
        check file:createDir(basePath, file:RECURSIVE);
    }

    byte[] fileFromDB = check getFileFromDB(submissionId);

    check io:fileWriteBytes(basePath + "/" + fileLocation, fileFromDB);

    return basePath + "/" + fileName + "/";
}

function getAndStoreTestCase(string challengeId, string location) returns error?{

    byte[] fileFromDB = check getTestCaseFromDB(challengeId);

    check io:fileWriteBytes(location + "/testsZip", fileFromDB);

}

# Description
#
# + arguments - String array which contains arguments to execute
# + workdingDir - Working directory
# + return - Returns an error if exists
function executeCommand(string[] arguments, string? workdingDir = ()) returns string[]|error {
    string[] newArgs = [];
    newArgs.push("/bin/bash", "-c");
    arguments.forEach(function(string arg) {
        newArgs.push(arg, "&&");
    });
    _ = newArgs.pop();

    utils:ProcessBuilder builder = check utils:newProcessBuilder2(newArgs);
    if workdingDir is string {
        builder = builder.directory2(utils:newFile2(workdingDir));
    }
    _ = builder.redirectErrorStream2(true);

    utils:Process p = check builder.start();
    utils:BufferedReader r = utils:newBufferedReader1(utils:newInputStreamReader1(p.getInputStream()));
    string?|utils:IOException line;
    string[] output = [];
    while (true) {
        line = check r.readLine();
        if (line == ()) {
            break;
        }
        io:println(line);
        output.push(check line);
    }
    return output;
}

isolated function getFileFromDB(string submissionId) returns byte[]|error {
    final mysql:Client dbClient = check new(host=HOST, user=USER, password=PASSWORD, port=PORT,database=DATABASE);
    byte[] submissionFileBlob = check dbClient->queryRow(
        `SELECT submission_file FROM submission WHERE submission_id = ${submissionId}`
    );
    check dbClient.close();
    return submissionFileBlob;
}

isolated function getTestCaseFromDB(string challengeId) returns byte[]|error {
    final mysql:Client dbClient = check new(host=HOST, user=USER, password=PASSWORD, port=PORT,database=DATABASE);
    byte[] testCaseFileBlob = check dbClient->queryRow(
        `SELECT testcase FROM challenge WHERE challenge_id = ${challengeId}`
    );
    check dbClient.close();
    return testCaseFileBlob;
}