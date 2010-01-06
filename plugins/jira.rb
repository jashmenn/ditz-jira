## git ditz plugin
## 
## Commands added:
##   jira-init: initializes jira variables
##   jira-pull: does a jira pull
##
## Usage: 
##   1. add a line "- jira" to the .ditz-plugins file in the project root
##   2. run ditz reconfigure, and enter the URL and credentials of your repo
##   3. 
## 
## See: http://docs.atlassian.com/software/jira/docs/api/rpc-jira-plugin/latest/index.html?com/atlassian/jira/rpc/soap/JiraSoapService.html
require 'jira4r/jira4r'
require 'pp'

class DateTime
  def to_time
    Time.parse(self.to_s)
  end
end

class Comment < Struct.new(:time, :what, :who, :comment)
  def sha
    SHA1.hexdigest [time, what, who, comment].join("\n")
  end
end

module JiraHelpers
  def init_jira(config)
    @jira ||= begin
      jira = Jira4R::JiraTool.new(2, config.jira_repo)
      jira.login(config.jira_username, config.jira_password)
      jira
    end
  end

  def jira
    @jira
  end

  # returns first filter matching +name+. nil otherwise
  def filter_by_name(name)
    jira.getSavedFilters.detect{|f| f.name == name}
  end

  # ditz => jira
  def issue_attributes_map
      {
        :title => :summary,
        :desc => [:description, proc{|n| n || "" }], # jira allows empty descriptions
        :type => [:type, proc{|n|
        # valid ditz: [ :bugfix, :feature, :task ]
        convert_type_to_ditz(issue_types.detect{|type| type.id.to_s == n.to_s}.name.downcase.intern) rescue :task # todo
      }],
        :component => [:components, proc{|n| 
        n.first.name
      }],
        :release => [:fixVersions, proc{|n| n.first}],
        :reporter => :reporter,

        :status => [:status, proc{|n|
         matching_status = statuses.detect{|s| s.id.to_s == n.to_s }
         status_map[matching_status.name]
      }],
        :disposition => :resolution, 
        :creation_time => [:created, proc {|n| n.to_time }
      ]}
  end

  # valid ditz: [:unstarted, :in_progress, :paused, :closed]
  def status_map
    {"Open" => :unstarted, "In Progress" => :in_progress, "Reopened" => :unstarted, "Resolved" => :closed, "Closed" => :closed}
  end


  def convert_to_ditz_issue(jira_issue, project, config)
    attributes = {
      :jira_id => jira_issue.key,
      :jira_repo => config.jira_repo
    }
    issue_attributes_map.each do |k,v|
      attributes[k.to_s.intern] = v.kind_of?(Array) ? v.last.call(jira_issue.send(v.first)) : jira_issue.send(v)
    end
    Ditz::Issue.create attributes, [config, project]
  end

  def issue_types
    @issue_types ||= begin
                       jira.getIssueTypes
                     end
  end
  def statuses
    @statuses ||= begin
                       jira.getStatuses
                  end
  end

  # todo
  def convert_type_to_ditz(type)
    return :bugfix if type == :issue
    return type
  end

end

module Ditz
class Issue
  # field :git_branch, :ask => false

  # def git_commits
  #   return @git_commits if @git_commits

  #   filters = ["--grep=\"Ditz-issue: #{id}\""]
  #   filters << "master..#{git_branch}" if git_branch

  #   output = filters.map do |f|
  #     `git log --pretty=format:\"%aD\t%an <%ae>\t%h\t%s\" #{f} 2> /dev/null`
  #   end.join

  #   @git_commits = output.split(/\n/).map { |l| l.split("\t") }.
  #     map { |date, email, hash, msg| [Time.parse(date).utc, email, hash, msg] }
  # end

  field :jira_repo
  field :jira_id

  def jira_sha
    SHA1.hexdigest [jira_repo, jira_id].join("\n")
  end

  def logt time, what, who, comment
    add_log_event([time, who, what, comment])
  end
end

class Config
  field :jira_repo, :prompt => "JIRA repository (Example: http://jira.yourdomain.com)", :default => ""
  field :jira_username, :prompt => "JIRA username", :default => ""
  field :jira_password, :prompt => "JIRA password", :default => ""
  field :jira_filter, :prompt => "JIRA Filter", :default => ""
  field :jira_project, :prompt => "JIRA Project (Example: RND)", :default => ""
end

class ScreenView
  # add_to_view :issue_summary do |issue, config|
  #   " Git branch: #{issue.git_branch || 'none'}\n"
  # end

  # add_to_view :issue_details do |issue, config|
  #   commits = issue.git_commits[0...5]
  #   next if commits.empty?
  #   "Recent commits:\n" + commits.map do |date, email, hash, msg|
  #     "- #{msg} [#{hash}] (#{email.shortened_email}, #{date.ago} ago)\n"
  #    end.join + "\n"
  # end
end

class Operator
  include JiraHelpers
  # operation :set_branch, "Set the git feature branch of an issue", :issue, :maybe_string
  # def set_branch project, config, issue, maybe_string
  #   puts "Issue #{issue.name} currently " + if issue.git_branch
  #     "assigned to git branch #{issue.git_branch.inspect}."
  #   else
  #     "not assigned to any git branch."
  #   end

  #   branch = maybe_string || ask("Git feature branch name:")
  #   return unless branch

  #   if branch == issue.git_branch
  #     raise Error, "issue #{issue.name} already assigned to branch #{issue.git_branch.inspect}"
  #   end

  #   puts "Assigning to branch #{branch.inspect}."
  #   issue.git_branch = branch
  # end

  operation :jira_init, "initializes jira variables" do
  end

  def jira_init project, config, opts
    init_jira(config)

    # initialize componenets
    components = jira.getComponents(config.jira_project)
    components.each do |c|
      unless project.components.detect{|existing| existing.name == c.name}
        component = Component.create({:name => c.name}, [project, config])
        project.add_component component
        puts "Imported component #{component.name}."
      end
    end
  end

  operation :jira_pull, "does a jira pull" do
  end

  def jira_pull project, config, opts
    init_jira(config)

    filter = filter_by_name(config.jira_filter)
    issues = jira.getIssuesFromFilter(filter.id)

    issues.each do |issue|
      ditz_issue = convert_to_ditz_issue(issue, project, config)
      use = nil

      # see if issue exists
      if existing_issue = project.issues.detect{|i| i.jira_sha == ditz_issue.jira_sha}
        use = existing_issue
      else # create it if not
        create_issue(project, config, opts, ditz_issue)
        use = ditz_issue
      end

      # get comments
      jcomments = jira.getComments(use.jira_id)
      pp jcomments

      #  issue.log "commented", config.user, comment
      pp use.log_events
    end

    # create_issue_if_needed(project, config, opts, issues.first)

  end

  private

  def create_issue project, config, opts, issue
    issue.log "imported from jira", config.user, "imported"
    puts "Importing issue \"#{issue.title}\" (#{issue.id} | #{issue.jira_id})."
    project.add_issue issue
    project.assign_issue_names!
  end


end

end
