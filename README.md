#  TrueTree

<p align="center"><img src="https://themittenmac.com/wp-content/uploads/2020/02/Frame-5-scaled.jpg"></p>

**About** \
Read all about the TrueTree concept [here](https://themittenmac.com/the-truetree-concept/)

TrueTree is more than just a pstree command for macOS. It is used to display a process tree for current running processes while using a hierarchy built on additoinal pids that can be collected from the operating system.  The standard process tree on macOS that can be built with traditional pids and ppids is less than helpful on macOS due to all the XPC communication at play.  The vast majority of processes end up having a parent process of launchd. TrueTree however displays a process tree that is meant to be useful to incident responders, threat hunters, researchers, and everything in between!  

Major Update:
Because of the ever changing features on macOS, since macOS 11 some features don't operate quite the same as they used to when I wrote the original blog post for TrueTree. Apple has introduced the addition of a new process "runningboardd" which ends up being the true parent of many processes. To get around this TrueTree was updated to use the Application Services framework which allowed for acquiring the true parent in some scenarios. However, this no longer allows for the acquiring of a true parent process if that parent process has terminated. Making it difficult to pinpoint some true parents such as the "open" command. A small price to pay to ensure TrueTree continues to operate across macOS releases. Some other signs of a true parent can often be found inside of the launchctl procinfo output. This might be taken into consideration in the future

New in TrueTree 0.9:
Root is no longer required to run TrueTree. Without root, responsible pids are estimated from process coalitions, and network connections are limited to your own processes. A coalition is a group of related processes that the macOS kernel tracks together, such as an app and the helpers and XPC services it launches.

When run as root, TrueTree uses the original libquarantine method, which is the most reliable. To use the coalition method as root instead, pass  --acquire-responsible-via-coalition .

New tests have also been added, including coalition tests that guard against macOS quietly changing a private kernel interface that TrueTree depends on.

**./TrueTree -h** \
--nocolor -> Do not color code items in output
--timeline  -> Sort and print all processes by their creation timestamp
--timestamps -> Include process timestamps
--standard -> Print the standard Unix tree instead of TrueTree
--sources -> Print the source of where each processes parent came from
--nonetwork -> Do not print network connection
--nopid -> Do not print the pid next to each process
--nopath -> Print process name only instead of full paths
--json -> Output JSON instead of text (works with --standard, --timeline, and -o)
--version -> Print the TrueTree version number
--acquire-responsible-via-coalition
                 Estimate responsible pids from process coalitions instead of libquarantine.
                 Coalitions are always used when not running as root.
-o <filename> -> output to file


**./TrueTree** \
Displays an enhanced process tree using the TrueTree concept
<p align="center"><img src="https://themittenmac.com/images/truetree-images/truetree_output.png"></p>
<br/><br/>

**./TrueTree --standard** \
For tree output based on standard pids and ppids use --standard
<p align="center"><img src="https://themittenmac.com/images/truetree-images/tt_standard.png"></p>
<br/><br/>

**./TrueTree --timestamps** \
For output in either format with process create time added use the --timestamps option
<p align="center"><img src="https://themittenmac.com/images/truetree-images/tt_timestamps.png"></p>
<br/><br/>

**./TrueTree --sources** \
To show where each parent pid was acquired from use the --sources option
<p align="center"><img src="https://themittenmac.com/images/truetree-images/tt_sources.png"></p>
<br/><br/>

**./TrueTree --timeline** \
Does not collect a tree. Instead just prints processes sorted by creation time
<p align="center"><img src="https://themittenmac.com/wp-content/uploads/2022/12/tt_timeline.png"></p>
