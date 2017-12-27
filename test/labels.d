import utils;

// send normal label event --> nothing
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/issues/4921/labels",
    );

    postGitHubHook("dlang_phobos_label_4921.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["pull_request"]["state"] = "open";
    }.toDelegate);
}

// send auto-merge label event, but closed PR --> nothing
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            j[0]["name"] = "auto-merge";
        },
    );

    postGitHubHook("dlang_phobos_label_4921.json");
}

// send auto-merge label event --> try merge --> failure
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            j[0]["name"] = "auto-merge";
        },
        "/github/repos/dlang/phobos/issues/4921/events", (ref Json j) {
            assert(j[1]["event"] == "labeled");
            j[1]["label"]["name"] = "auto-merge";
        },
        "/github/users/9il",
        "/github/repos/dlang/phobos/pulls/4921/merge", (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            // https://developer.github.com/v3/pulls/#response-if-merge-cannot-be-performed
            assert(req.json["sha"] == "d2c7d3761b73405ee39da3fd7fe5030dee35a39e");
            assert(req.json["merge_method"] == "merge");
            assert(req.json["commit_message"] == "Issue 8573 - A simpler Phobos function that returns the index of the …\n"~
                   "merged-on-behalf-of: Ilya Yaroshenko <testmail@example.com>");
            res.statusCode = 405;
        }
    );

    postGitHubHook("dlang_phobos_label_4921.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["pull_request"]["state"] = "open";
    }.toDelegate);
}

// send auto-merge-squash label event --> try merge --> success
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/phobos/pulls/4921/commits",
        "/github/repos/dlang/phobos/issues/4921/labels", (ref Json j) {
            j[0]["name"] = "auto-merge-squash";
        },
        "/github/repos/dlang/phobos/issues/4921/events", (ref Json j) {
            assert(j[1]["event"] == "labeled");
            j[1]["label"]["name"] = "auto-merge-squash";
        },
        "/github/users/9il",
        "/github/repos/dlang/phobos/pulls/4921/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.json["sha"] == "d2c7d3761b73405ee39da3fd7fe5030dee35a39e");
            assert(req.json["merge_method"] == "squash");
            assert(req.json["commit_message"] == "Issue 8573 - A simpler Phobos function that returns the index of the …\n"~
                   "merged-on-behalf-of: Ilya Yaroshenko <testmail@example.com>");
            res.statusCode = 200;
        }
    );

    postGitHubHook("dlang_phobos_label_4921.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["pull_request"]["state"] = "open";
        }
    );
}

// test whether users can label their PR via the title
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/dmd/pulls/6359/commits", (ref Json json) {
            json = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/issues/6359/comments?per_page=100",
        "/github/repos/dlang/dmd/issues/6359/comments?per_page=100",
        "/github/orgs/dlang/public_members?per_page=100",
        "/github/repos/dlang/dmd/issues/6359/labels",
        "/github/repos/dlang/dmd/issues/6359/labels",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.method == HTTPMethod.POST);
            assert(req.json.deserializeJson!(string[]) == ["trivial"]);
            res.writeVoidBody;
        }
    );

    postGitHubHook("dlang_dmd_open_6359.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["pull_request"]["title"] = "[Trivial] foo bar";
        }
    );
}

// test that not only a selection of labels is accepted
unittest
{
    setAPIExpectations(
        "/github/repos/dlang/dmd/pulls/6359/commits", (ref Json json) {
            json = Json.emptyArray;
        },
        "/github/repos/dlang/dmd/issues/6359/comments?per_page=100",
        "/github/repos/dlang/dmd/issues/6359/comments?per_page=100",
        "/github/orgs/dlang/public_members?per_page=100",
    );

    postGitHubHook("dlang_dmd_open_6359.json", "pull_request",
        (ref Json j, scope HTTPClientRequest req){
            j["pull_request"]["title"] = "[auto-merge] foo bar";
        }
    );
}

// reproduce behavior of vibe-d/vibe-core/22
unittest
{
    setAPIExpectations(
        "/github/repos/vibe-d/vibe-core/pulls/22/commits",
        "/github/repos/vibe-d/vibe-core/issues/22/labels",
        "/github/repos/vibe-d/vibe-core/issues/22/events",
        "/github/users/wilzbach",
        "/github/repos/vibe-d/vibe-core/pulls/22/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.json["sha"] == "04b3575c14dc7ad9971e19f153f3e3d712c1bdde");
            assert(req.json["merge_method"] == "merge");
            assert(req.json["commit_message"] == "Remove deprecated stdc import\n" ~
                    "merged-on-behalf-of: Sebastian Wilzbach <wilzbach@users.noreply.github.com>");
            res.statusCode = 200;
        }
    );

    postGitHubHook("vibe-d_vibe-core_label_22.json");
}

// Fix dlang-tour/core/583 issue with null on the homepage field
unittest
{
    setAPIExpectations(
        "/github/repos/dlang-tour/core/pulls/583/commits",
        "/github/repos/dlang-tour/core/issues/583/labels",
        "/github/repos/dlang-tour/core/issues/583/events",
        "/github/users/wilzbach",
        "/github/repos/dlang-tour/core/pulls/583/merge",
        (scope HTTPServerRequest req, scope HTTPServerResponse res) {
            assert(req.json["sha"] == "4941624d1af77e84565ec86979c21c1d582b1c06");
            assert(req.json["merge_method"] == "merge");
            assert(req.json["commit_message"] == "Run docker update async + remove previous versions\n" ~
                    "merged-on-behalf-of: Sebastian Wilzbach <wilzbach@users.noreply.github.com>");
        }
    );

    postGitHubHook("dlang-tour_core_label_583.json");
}
