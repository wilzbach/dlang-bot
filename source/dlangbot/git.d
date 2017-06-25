module dlangbot.git;

import std.conv, std.file, std.path, std.string, std.uuid;
import std.format, std.stdio;

import dlangbot.github;
import vibe.core.log;

string gitURL = "http://0.0.0.0:9006";

void rebase(PullRequest* pr)
{
    import std.process;
    auto uniqDir = tempDir.buildPath("dlang-bot-git", randomUUID.to!string.replace("-", ""));
    uniqDir.mkdirRecurse;
    scope(exit) uniqDir.rmdirRecurse;

    auto targetBranch = pr.base.ref_;
    auto remoteDir = pr.repoURL;

    logInfo("[git/%s]: cloning branch %s...", pr.repoSlug, targetBranch);
    auto pid = spawnShell("git clone -b %s %s %s".format(targetBranch, remoteDir, uniqDir));
    pid.wait;

    //auto git = "git -C %s ".format(uniqDir);
    //logInfo("[git/%s]: fetching repo...", pr.repoSlug);
    //pid = spawnShell(git ~ "fetch origin pull/%s/head:pr-%1$s".format(pr.number));
    //pid.wait;
    //logInfo("[git/%s]: switching to PR branch...", pr.repoSlug);
    //pid = spawnShell(git ~ "checkout pr-%s".format(pr.number));
    //pid.wait;
    //logInfo("[git/%s]: rebasing...", pr.repoSlug);
    //pid = spawnShell(git ~ "rebase " ~ targetBranch);
    //pid.wait;

    import std.net.curl, std.json;
    auto headSlug = pr.head.repo.fullName;
    auto headRef = pr.head.ref_;
    auto sep = gitURL.startsWith("http") ? "/" : ":";
    logInfo("[git/%s]: pushing... to %s", pr.repoSlug, gitURL);

    // TODO: use --force here
    auto cmd = "git push -vv %s%s%s HEAD:%s".format(gitURL, sep, headSlug, headRef);
    writeln("CMD");
    uniqDir.writeln;
    cmd.writeln;
    writeln("CMD");

    pid = spawnShell(cmd);
    //pid.wait;
    import vibe.core.core;
    import core.time;
    sleep(60.seconds);
    pid.wait;
}
