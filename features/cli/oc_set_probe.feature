Feature: oc_set_probe.feature

  # @author dyan@redhat.com
  # @case_id OCP-9870
  Scenario: OCP-9870 Set a probe to open a TCP socket
    Given I have a project
    When I run the :new_app client command with:
      | image_stream | openshift/mysql:5.6 |
      | env          | MYSQL_USER=user     |
      | env          | MYSQL_PASSWORD=pass |
      | env          | MYSQL_DATABASE=db   |
    Then the step should succeed
    Given I wait until the status of deployment "mysql" becomes :complete
    When I run the :set_probe client command with:
      | resource     | dc/mysql     |
      | readiness    |              |
      | open_tcp     | 3306         |
      | failure_threshold | 2          |
      | initial_delay_seconds | 10     |
      | period_seconds | 10            |
      | success_threshold | 3          |
    Then the step should succeed
    Given I wait until the status of deployment "mysql" becomes :complete
    And a pod becomes ready with labels:
      | deployment=mysql-2 |
    When I run the :describe client command with:
      | resource | pod |
      | l    | deployment=mysql-2 |
    Then the output should match:
      | Readiness |
      | tcp-socket :3306 |
      | delay=10s |
      | period=10s |
      | success=3 |
      | failure=2 |
    When I run the :set_probe client command with:
      | resource     | dc/mysql    |
      | readiness    |             |
      | open_tcp     | 45          |
      | o            | json        |
    Then the step should succeed
    When I save the output to file>file.json
    And I run the :set_probe client command with:
      | f         | file.json   |
      | readiness |             |
      | open_tcp  | 33          |
    Then the step should succeed
    When I wait until the status of deployment "mysql" becomes :running
    And I wait up to 60 seconds for the steps to pass:
    """
    When I run the :describe client command with:
      | resource | pod |
      | l    | deployment=mysql-4 |
    Then the output should match:
      | Readiness |
      | tcp-socket :33 |
      | probe failed |
    """

  # @author dyan@redhat.com
  # @case_id OCP-9871
  Scenario: OCP-9871 Set a probe over HTTPS/HTTP
    Given I have a project
    When I run the :new_app client command with:
      | image_stream | openshift/mysql:5.6 |
      | env          | MYSQL_USER=user     |
      | env          | MYSQL_PASSWORD=pass |
      | env          | MYSQL_DATABASE=db   |
    Then the step should succeed
    Given I wait until the status of deployment "mysql" becomes :complete
    When I run the :set_probe client command with:
      | resource     | dc/mysql  |
      | c            | mysql     |
      | readiness    |           |
      | get_url      | http://:8080/opt |
      | timeout_seconds | 30     |
    Then the step should succeed
    Given I wait until the status of deployment "mysql" becomes :running
    When I wait up to 30 seconds for the steps to pass:
    """
    When I run the :describe client command with:
      | resource | pod |
      | l    | deployment=mysql-2 |
    Then the output should contain:
      | Readiness |
      | http-get http://:8080/opt |
      | timeout=30s |
    """
    When I run the :set_probe client command with:
      | resource  | dc/mysql     |
      | readiness |              |
      | get_url   | https://127.0.0.1:1936/stats |
    Then the step should succeed
    Given I wait until the status of deployment "mysql" becomes :running
    When I wait up to 30 seconds for the steps to pass:
    """
    When I run the :describe client command with:
      | resource | pod |
      | l    | deployment=mysql-3 |
    Then the output should contain:
      | Readiness |
      | http-get https://127.0.0.1:1936/stats |
    """

  # @author dyan@redhat.com
  # @case_id OCP-9872
  Scenario: OCP-9872 Set an exec action probe
    Given I have a project
    When I run the :new_app client command with:
      | image_stream | openshift/mysql:5.6 |
      | env          | MYSQL_USER=user     |
      | env          | MYSQL_PASSWORD=pass |
      | env          | MYSQL_DATABASE=db   |
    Then the step should succeed
    Given I wait until the status of deployment "mysql" becomes :complete
    When I run the :set_probe client command with:
      | resource     | dc/mysql |
      | liveness     |          |
      | oc_opts_end  |          |
      | exec_command | true     |
    Then the step should succeed
    Given I wait until the status of deployment "mysql" becomes :complete
    And a pod becomes ready with labels:
      | deployment=mysql-2 |
    When I run the :describe client command with:
      | resource | pod |
      | l    | deployment=mysql-2 |
    Then the output should contain:
      | Liveness     |
      | true         |
    When I run the :set_probe client command with:
      | resource     | dc/mysql |
      | liveness     |          |
      | oc_opts_end  |          |
      | exec_command | false    |
    Then the step should succeed
    Given I wait until the status of deployment "mysql" becomes :complete
    And a pod becomes ready with labels:
      | deployment=mysql-3 |
    When I run the :describe client command with:
      | resource | pod |
      | l    | deployment=mysql-3 |
    Then the output should contain:
      | Liveness     |
      | false        |

