Feature: projects related features via cli

  # @author yapei@redhat.com
  # @case_id OCP-11887
  Scenario: OCP-11887 Could delete all resources when delete the project
    Given a 5 characters random string of type :dns is stored into the :prj_name clipboard
    When I run the :new_project client command with:
      | project_name | <%= cb.prj_name %> |
    Then the step should succeed
    # TODO: yapei, this is a work around for AEP, please add step `the step should succeed` according to latest good solution
    When I create a new application with:
      | docker image | openshift/mysql-55-centos7 |
      | code         | https://github.com/openshift/ruby-hello-world |
      | n            | <%= cb.prj_name %>           |
    And the output should contain:
      | mysql-55-centos7 |
      | ruby-hello-world |
    ### get project resource
    When I run the :get client command with:
      | resource | deploymentconfigs |
      | n        | <%= cb.prj_name %>  |
    Then the step should succeed
    And the output should contain:
      | mysql-55-centos7 |
      | ruby-hello-world |
    When I run the :get client command with:
      | resource | services |
      | n        | <%= cb.prj_name %> |
    Then the step should succeed
    And the output should contain:
      | mysql-55-centos7 |
      | ruby-hello-world |
    When I run the :get client command with:
      | resource | is |
      | n        | <%= cb.prj_name %> |
    Then the step should succeed
    And the output should contain:
      | mysql-55-centos7 |
      | ruby-hello-world |
    ### delete this project,make sure project is deleted
    Given the "<%= cb.prj_name %>" project is deleted
    ### get project resource after project is deleted
    When I run the :get client command with:
      | resource | deploymentconfigs |
      | n        | <%= cb.prj_name %>  |
    Then the step should fail
    And the output should not contain:
      | mysql-55-centos7 |
      | ruby-hello-world |
    When I run the :get client command with:
      | resource | services |
      | n        | <%= cb.prj_name %> |
    Then the step should fail
    And the output should not contain:
      | mysql-55-centos7 |
      | ruby-hello-world |
    When I run the :get client command with:
      | resource | pods  |
      | n        | <%= cb.prj_name %> |
    Then the step should fail
    And the output should not contain:
      | mysql-55-centos7-1-deploy |

    ### create a project with same name, no context for this new one
    And I wait for the steps to pass:
    """
    Given I run the :new_project client command with:
      | project_name | <%= cb.prj_name %> |
    And the step should succeed
    """
    Then I run the :status client command
    And the output should contain:
      | no services, deployment configs |

  # @author cryan@redhat.com
  # @case_id OCP-12193
  @admin
  Scenario: OCP-12193 User can get node selector from a project
    Given  an 8 character random string of type :dns is stored into the :oadmproj1 clipboard
    Given  an 8 character random string of type :dns is stored into the :oadmproj2 clipboard
    When admin creates a project with:
      | project_name | <%= cb.oadmproj1 %> |
      | admin | <%= user.name %> |
    Then the step should succeed
    When admin creates a project with:
      | project_name | <%= cb.oadmproj2 %> |
      | node_selector | env=qa |
      | description | testnodeselector |
      | admin | <%= user.name %> |
    Then the step should succeed
    When I run the :describe client command with:
      | resource | project |
      | name | <%= cb.oadmproj1 %> |
    Then the step should succeed
    And the output should match "Node Selector:\s+<none>"
    When I run the :describe client command with:
      | resource | project |
      | name | <%= cb.oadmproj2 %> |
    Then the step should succeed
    And the output should match "Node Selector:\s+env=qa"

  # @author cryan@redhat.com
  # @case_id OCP-12561
  Scenario: OCP-12561 Could remove user and group from the current project
    Given I have a project
    When I run the :oadm_add_role_to_user client command with:
      | role_name        | admin                              |
      | user_name        | <%= user(1, switch: false).name %> |
      | rolebinding_name | admin                              |
    Then the step should succeed
    When I run the :oadm_add_role_to_group client command with:
      | role_name        | admin                                                     |
      | group_name       | system:serviceaccounts:<%= user(1, switch: false).name %> |
      | rolebinding_name | admin                                                     |
    Then the step should succeed
    When I run the :get client command with:
      | resource      | rolebinding |
      | resource_name | admin       |
      | o             | wide        |
    Then the step should succeed
    And the output should match:
      | admin.*<%= user.name %>, <%= user(1, switch: false).name %>.*system:serviceaccounts:<%= user(1, switch: false).name %> |
    When I run the :policy_remove_group client command with:
      | group_name | system:serviceaccounts:<%= user(1, switch: false).name %> |
    Then the step should succeed
    And the output should contain "Removing admin from groups"
    When I run the :get client command with:
      | resource      | rolebinding |
      | resource_name | admin       |
      | o             | wide        |
    Then the step should succeed
    And the output should match:
      | admin.*<%= user.name %>, <%= user(1, switch: false).name %> |
    And the output should not contain "system:serviceaccounts:<%= user(1, switch: false).name %>"

  # @author yinzhou@redhat.com
  # @case_id OCP-11201
  Scenario: OCP-11201 Process with default FSGroup id can be ran when using the default MustRunAs as the RunAsGroupStrategy
    Given I have a project
    When I run the :create client command with:
      | f | https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/pods/hello-pod.json |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=hello-openshift |
    Then the expression should be true> project.uid_range(user:user).begin == pod.fs_group(user:user)

