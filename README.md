# clone_mysqldb
clone a mysql database (remote/local) from A to B

Premise
---------------------
The tool will allow you to clone a database through a wizard:
- import through a dump previously executed and already saved locally
- by running a mysqldump * "** hot backup **" * and then importing it (recommended procedure only in DEV environment)

Note
---------------------------
- database_app_data: looks for the dev.nidoma.com_data.sql file that contains the SQL to be initialized after the DB cloning. e.g .: default dev INSERT which allow the correct initialization of the application
- backup_path: look for the path which contains the database backup files to draw from

TODO
---------------------------
- database_app_data: to be parameterized, giving the possibility to choose the path of a file that contains the SQL to be initialized after the DB cloning.
- backup_path: to be parameterized, giving the possibility to choose the path where the backups of the databases are hosted.
- behavior in case of wrong password of the db after the first export: instead of terminating the script with errors, it would be the case to put the step in loop until the user decides to give up and then of his will to terminate the execution.

Resources management
---------------------------
### dbpreset.conf
It is the configuration file with the resources you want to interface with.
The file has a configuration of this type, e.g .:
\ #dbhost | dbname | dbuser | port (default 3306)
where the first row are the keys of the table and following the data:
\ #myhostname | mydatabase | myuser | myport (default 3306)
To add a new resource just create a new line at the end of the file.
**N.B .: it is important to leave a newline at the end of the file otherwise the last line will be ignored**
