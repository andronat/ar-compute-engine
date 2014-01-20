REGISTER /usr/libexec/ar-compute/MyUDF.jar
REGISTER /usr/lib/pig/datafu-0.0.4-cdh4.5.0.jar
REGISTER /usr/libexec/ar-local-compute/lib/mongo-java-driver-2.11.3.jar   -- mongodb java driver  
REGISTER /usr/libexec/ar-local-compute/lib/mongo-hadoop-core.jar          -- mongo-hadoop core lib
REGISTER /usr/libexec/ar-local-compute/lib/mongo-hadoop-pig.jar           -- mongo-hadoop pig lib

define FirstTupleFromBag datafu.pig.bags.FirstTupleFromBag();
define ApplyProfiles     myudf.ApplyProfiles();
define AddTopology       myudf.AddTopology();

--- e.g. in_date = 2013-05-29, PREV_DATE = 2013-05-28
%declare PREV_DATE `date --date=@$(( $(date --date=$in_date +%s) - 86400 )) +'%Y-%m-%d'`
%declare PREVDATE `echo $PREV_DATE | sed 's/-//g'`
%declare CUR_DATE `echo $in_date | sed 's/-//g'`

--- sanitize......
%declare hack1 `echo sitereports_`
%declare OUT1 `echo $out_path$hack1$in_date`

%declare hack2 `echo apireports_`
%declare OUT2 `echo $out_path$hack2$in_date`

%declare IN_PREVDATE `echo $PREV_DATE | sed 's/-/_/g'`
%declare IN_CUR_DATE `echo $in_date | sed 's/-/_/g'`

--- There is a bug in Pig that forbids shell output longer than 32kb. Issue: https://issues.apache.org/jira/browse/PIG-3515
%declare DOWNTIMES  `cat $downtimes_file`
%declare TOPOLOGY   `cat $topology_file1`
%declare TOPOLOGY2  `cat $topology_file2`
%declare TOPOLOGY3  `cat $topology_file3`
%declare POEMS      `cat $poem_file`
%declare WEIGHTS    `cat $weights_file`
%declare HLP        `echo ""` --- `cat $hlp` --- high level profile.

SET mapred.child.java.opts -Xmx2048m
SET mapred.map.tasks.speculative.execution false
SET mapred.reduce.tasks.speculative.execution false

---SET mapred.min.split.size 3000000;
---SET mapred.max.split.size 3000000;
---SET pig.noSplitCombination true;

SET hcat.desired.partition.num.splits 2;

SET io.sort.factor 100;
SET mapred.job.shuffle.merge.percent 0.33;
SET pig.udf.profile true;

--- Get beacons (logs from previous day)
beacons = load '$input_path$IN_PREVDATE.out' using PigStorage('\\u001') as (time_stamp:chararray, metric:chararray, service_flavour:chararray, hostname:chararray, status:chararray, vo:chararray, vofqan:chararray, profile:chararray);

--- Get current logs
current_logs = load '$input_path$IN_CUR_DATE.out' using PigStorage('\\u001') as (time_stamp:chararray, metric:chararray, service_flavour:chararray, hostname:chararray, status:chararray, vo:chararray, vofqan:chararray, profile:chararray);

--- Merge current logs with beacons
logs = UNION current_logs, beacons;

--- MAIN ALGORITHM ---

--- Group rows so we can have for each hostname and flavor, the applied poem profile with reports
profile_groups = GROUP logs BY (hostname, service_flavour, profile) PARALLEL 1;

--- After the grouping, we append the actual rules of the POEM profiles
profiled_logs = FOREACH profile_groups 
        GENERATE group.hostname as hostname, group.service_flavour as service_flavour, 
                 group.profile as profile, 
                 FLATTEN(FirstTupleFromBag(logs.vo,null)) as vo, 
                 logs.(metric, status, time_stamp) as timeline;


--- We calculate the timelines and create an integral of all reports
timetables = FOREACH profiled_logs {
        timeline_s = ORDER timeline BY time_stamp;
        GENERATE hostname, service_flavour, profile, vo, FLATTEN(ApplyProfiles(timeline_s, profile, '$PREV_DATE', hostname, service_flavour, '$CUR_DATE', '$DOWNTIMES', '$POEMS')) as (date, timeline);
};

timetables2 = FOREACH timetables GENERATE date as dates, hostname, service_flavour, profile, vo, myudf.TimelineToPercentage(*) as timeline;

--- Join topology with logs, so we have have for each log raw all topology information
topologed = FOREACH timetables GENERATE date, profile, vo, timeline, hostname, service_flavour, FLATTEN(AddTopology(hostname, service_flavour, '$TOPOLOGY', '$TOPOLOGY2', '$TOPOLOGY3'));

topology_g = GROUP topologed BY (date, site, profile, production, monitored, scope, ngi, infrastructure, certification_status, site_scope) PARALLEL 1;

topology = FOREACH topology_g {
        t = ORDER topologed BY service_flavour;
        GENERATE group.date as dates, group.site as site, group.profile as profile,
            group.production as production, group.monitored as monitored, group.scope as scope,
            group.ngi as ngi, group.infrastructure as infrastructure,
            group.certification_status as certification_status, group.site_scope as site_scope,
            FLATTEN(myudf.AggregateSiteAvailability(t, '$HLP', '$WEIGHTS', group.site)) as (availability, reliability, up, unknown, downtime, weight);
};

top_marked = FOREACH topology GENERATE dates as dt, site as s, profile as p, production as pr, monitored as m, scope as sc, ngi as n, infrastructure as i, certification_status as cs, site_scope as ss, availability as a, reliability as r, up as up, unknown as u, downtime as d, weight as hs;
tim_marked = FOREACH timetables2 GENERATE dates as d, hostname as h, service_flavour as sf, profile as p, vo as vo, timeline as tm;

STORE topology    INTO 'mongodb://$mongoServer/AR.sites'     USING com.mongodb.hadoop.pig.MongoInsertStorage();
STORE timetables2 INTO 'mongodb://$mongoServer/AR.timelines' USING com.mongodb.hadoop.pig.MongoInsertStorage();