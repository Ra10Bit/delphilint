/*
 * DelphiLint Server
 * Copyright (C) 2023 Integrated Application Development
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
package au.com.integradev.delphilint.remote;

import au.com.integradev.delphilint.analysis.DelphiIssue;
import au.com.integradev.delphilint.analysis.DelphiIssue.RemoteMetadata;
import au.com.integradev.delphilint.analysis.TrackableWrappers;
import au.com.integradev.delphilint.analysis.TrackableWrappers.ClientTrackable;
import au.com.integradev.delphilint.analysis.TrackableWrappers.ServerTrackable;
import java.util.Collection;
import java.util.HashSet;
import java.util.LinkedList;
import java.util.Map;
import java.util.Map.Entry;
import java.util.Queue;
import java.util.Set;
import java.util.function.Predicate;
import java.util.stream.Collectors;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.jetbrains.annotations.Nullable;
import org.sonarsource.sonarlint.core.analysis.api.Issue;
import org.sonarsource.sonarlint.core.issuetracking.Tracker;
import org.sonarsource.sonarlint.core.issuetracking.Tracking;

public class SonarServerUtils {
  private static final Logger LOG = LogManager.getLogger(SonarServerUtils.class);

  private SonarServerUtils() {
    // utility class
  }

  public static Set<DelphiIssue> postProcessIssues(
      Collection<String> fileRelativePaths,
      @Nullable Collection<String> testFileRelativePaths,
      Collection<Issue> issues,
      SonarHost host)
      throws SonarHostException {
    LOG.info("Post processing {} issues", issues.size());

    testFileRelativePaths =
        getTestRelativePathsIfNull(testFileRelativePaths, host).stream()
            .filter(fileRelativePaths::contains)
            .collect(Collectors.toSet());

    Set<String> mainFileRelativePaths =
        fileRelativePaths.stream()
            .filter(Predicate.not(testFileRelativePaths::contains))
            .collect(Collectors.toSet());

    issues =
        pruneResolvedIssues(
            mainFileRelativePaths,
            testFileRelativePaths,
            populateIssueMessages(host, issues),
            host);
    Map<Issue, RemoteMetadata> metadataMap =
        getRemoteIssueData(mainFileRelativePaths, testFileRelativePaths, issues, host);

    return issues.stream()
        .map(issue -> new DelphiIssue(issue, metadataMap.getOrDefault(issue, null)))
        .collect(Collectors.toSet());
  }

  private static Collection<String> getTestRelativePathsIfNull(
      @Nullable Collection<String> testFileRelativePaths, SonarHost host)
      throws SonarHostException {
    if (testFileRelativePaths == null) {
      return host.getTestFilePaths();
    } else {
      return testFileRelativePaths;
    }
  }

  private static Set<Issue> populateIssueMessages(SonarHost host, Collection<Issue> issues)
      throws SonarHostException {
    var ruleNameMap = host.getRuleNamesByRuleKey();

    return issues.stream()
        .map(
            oldIssue -> {
              if (oldIssue.getMessage() == null || oldIssue.getMessage().isEmpty()) {
                return new Issue(
                    oldIssue.getRuleKey(),
                    ruleNameMap.get(oldIssue.getRuleKey()),
                    oldIssue.getOverriddenImpacts(),
                    oldIssue.getTextRange(),
                    oldIssue.getInputFile(),
                    oldIssue.flows(),
                    oldIssue.quickFixes(),
                    oldIssue.getRuleDescriptionContextKey());
              } else {
                return oldIssue;
              }
            })
        .collect(Collectors.toSet());
  }

  private static Tracking<ClientTrackable, ServerTrackable> matchIssues(
      Collection<Issue> localIssues, Collection<RemoteIssue> remoteIssues) {
    Queue<ClientTrackable> clientTrackables =
        localIssues.stream()
            .map(TrackableWrappers.ClientTrackable::new)
            .collect(Collectors.toCollection(LinkedList::new));

    Set<TrackableWrappers.ServerTrackable> serverTrackables = new HashSet<>();

    for (RemoteIssue remoteIssue : remoteIssues) {
      serverTrackables.add(new TrackableWrappers.ServerTrackable(remoteIssue));
    }

    Tracker<ClientTrackable, ServerTrackable> tracker = new Tracker<>();
    return tracker.track(() -> clientTrackables, () -> serverTrackables);
  }

  private static Map<Issue, RemoteMetadata> getRemoteIssueData(
      Collection<String> fileRelativePaths,
      Collection<String> testFileRelativePaths,
      Collection<Issue> issues,
      SonarHost host)
      throws SonarHostException {
    Collection<RemoteIssue> remoteIssues =
        host.getUnresolvedIssues(fileRelativePaths, testFileRelativePaths);
    var tracking = matchIssues(issues, remoteIssues);

    Map<Issue, RemoteMetadata> metadataMap =
        tracking.getMatchedRaws().entrySet().stream()
            .map(
                entry -> {
                  RemoteIssue remote = entry.getValue().getClientObject();

                  return Map.entry(
                      entry.getKey().getClientObject(),
                      new RemoteMetadata(
                          remote.getAssignee(), remote.getCreationDate(), remote.getStatus()));
                })
            .collect(Collectors.toMap(Entry::getKey, Entry::getValue));

    LOG.info(
        "{}/{} issues matched with {} client issues and had metadata retrieved",
        metadataMap.size(),
        issues.size(),
        remoteIssues.size());

    return metadataMap;
  }

  private static Set<Issue> pruneResolvedIssues(
      Collection<String> fileRelativePaths,
      Collection<String> testFileRelativePaths,
      Collection<Issue> issues,
      SonarHost host)
      throws SonarHostException {
    Collection<RemoteIssue> resolvedIssues =
        host.getResolvedIssues(fileRelativePaths, testFileRelativePaths);
    var tracking = matchIssues(issues, resolvedIssues);

    Set<Issue> returnIssues = new HashSet<>();
    tracking
        .getUnmatchedRaws()
        .iterator()
        .forEachRemaining(trackable -> returnIssues.add(trackable.getClientObject()));

    LOG.info(
        "{}/{} issues matched with {} resolved server issues and discarded",
        issues.size() - returnIssues.size(),
        issues.size(),
        resolvedIssues.size());

    return returnIssues;
  }
}
