#  TrueTree

<p align="center"><img src="https://themittenmac.com/wp-content/uploads/2020/02/Frame-5-scaled.jpg"></p>

**About** \
Read all about the TrueTree concept [here](https://themittenmac.com/the-truetree-concept/)


TrueTree is more than just a pstree command for macOS. It is used to display a process tree for current running processes while using a hierarchy built on additoinal pids that can be collected from the operating system.  The standard process tree on macOS that can be built with traditional pids and ppids is less than helpful on macOS due to all the XPC communication at play.  The vast majority of processes end up having a parent process of launchd. TrueTree however displays a process tree that is meant to be useful to incident responders, threat hunters, researchers, and everything in between!  

Major Update:
Because of the ever changing features on macOS, since macOS 11 some features don't operate quite the same as they used to when I wrote the original blog post for TrueTree. Apple has introduced the addition of a new process "runningboardd" which ends up being the true parent of many processes. To get around this TrueTree was updated to use the Application Services framework which allowed for aquiring the true parent in some scenarios. However, this no longer allows for the aquiring of a true parent process if that parent process has terminated. Making it difficult to pinpoint some true parents such as the "open" command. A small price to pay to ensure TrueTree continues to operate across macOS releases. Some other signs of a true parent can often be found inside of the launchctl procinfo output. This might be taken into consideration in the future.

**./TrueTree -h** \
--nocolor -> Do not color code items in output
--notree  -> Do not print tree format. Just print in list format
--timestamps -> Include process timestamps
--standard -> Print the standard Unix tree instead of TrueTree
--sources -> Print the source of where each processes parent came from
--version -> Print the TrueTree version number
-o <filename> -> output to file

<span style="color:blue">Note: Requires Root</span>

**./TrueTree** \
Displays an enhanced process tree using the TrueTree concept
<p align="center"><img src="https://themittenmac.com/wp-content/uploads/2020/02/bigger_preview_photo.png"></p>

<br/><br/>

**./TrueTree --standard** \
For tree output based on standard pids and ppids use --standard
<p align="center"><img src="https://themittenmac.com/wp-content/uploads/2020/03/tt_standard.png"></p>
<br/><br/>

**./TrueTree --timestamps** \
For output in either format with process create time added use the --timestamps option
<p align="center"><img src="https://themittenmac.com/wp-content/uploads/2020/03/tt_timestamps.png"></p>

**./TrueTree --sources** \
To show where each parent pid was aquired from use the --sources option
<p align="center"><img src="https://themittenmac.com/wp-content/uploads/2022/03/tt_sources.png"></p>
