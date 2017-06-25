import utils;

// send rebase label
unittest
{
    setAPIExpectations();
    import std.stdio;

    // first request by the git client
    // server returns a list of all refs it knows
    gitInfoRefs = (string user, string repo) {
        "requesting refs".writeln;
        return [
            GitInfoRef("6ed2e15cf4a35e274adb8385b3ee8125326509f9", "refs/heads/foo"),
            GitInfoRef("6e79d22fdfda446601d969ce77e406b9a5506de9", "refs/heads/Issue_8573"),
            GitInfoRef("6e79d22fdfda446601d969ce77e406b9a5506de8", "refs/heads/master"),
        ];
    };


    // git client "reports" new refs to the server
    gitReportRefs = (ClientReq clientReq) {
        clientReq.writeln;
        return [
            GitReportRef(GitReportRef.status.ok, "refs/heads/Issue_8573")
        ];
    };

    postGitHubHook("dlang_phobos_label_4921.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["pull_request"]["state"] = "open";
            j["label"]["name"] = "bot-rebase";
    }.toDelegate);
}
