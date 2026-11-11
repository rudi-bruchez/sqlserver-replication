package reader

import (
	"database/sql"
	"fmt"
	"slices"
	"sort"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

func (e *exporter) readPublications() error {
	e.pubIndex = map[int]int{}
	rows, err := e.src.Publisher.QueryContext(e.ctx, qPublications)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			pubid, replFreq, status, syncMethod, retention, options, ftpPort int
			independent, immediate, internet, push, pull, anonymous          int
			syncTran, queuedTran, dts, subCopy, fromBackup, ddl              int
			inDefault, compress                                              int
			description, altFolder, preScript, postScript                    string
			ftpAddress, ftpSubdirectory, ftpLogin                            string
			p                                                                model.Publication
		)
		err := rows.Scan(&pubid, &p.Name, &description,
			&replFreq, &status, &syncMethod, &retention,
			&independent, &immediate, &internet, &push, &pull, &anonymous,
			&syncTran, &queuedTran, &dts, &subCopy, &fromBackup, &ddl,
			&options, &inDefault,
			&altFolder, &preScript, &postScript, &compress,
			&ftpAddress, &ftpPort, &ftpSubdirectory, &ftpLogin)
		if err != nil {
			return err
		}
		p.Description = model.Ptr(description)
		p.Type = model.Ptr(decode.PublicationType(replFreq))
		p.Status = model.Ptr(decode.PublicationStatus(status))
		p.SyncMethod = model.Ptr(decode.SyncMethod(syncMethod))
		p.RetentionHours = model.Ptr(retention)
		p.IndependentAgent = model.Ptr(independent != 0)
		p.ImmediateSync = model.Ptr(immediate != 0)
		p.AllowPush = model.Ptr(push != 0)
		p.AllowPull = model.Ptr(pull != 0)
		p.AllowAnonymous = model.Ptr(anonymous != 0)
		p.AllowSubscriptionCopy = model.Ptr(subCopy != 0)
		p.AllowInitializeFromBackup = model.Ptr(fromBackup != 0)
		p.ReplicateDDL = model.Ptr(ddl != 0)
		p.AllowDrop = model.Ptr(options&decode.PubOptionAllowDrop != 0)
		p.AllowPartitionSwitch = model.Ptr(options&decode.PubOptionAllowPartitionSwitch != 0)
		p.ReplicatePartitionSwitch = model.Ptr(options&decode.PubOptionReplicatePartitionSwitch != 0)
		p.EnabledForHetSub = model.Ptr(options&decode.PubOptionNonSQLSubscribers != 0)
		p.Snapshot = &model.Snapshot{
			EnabledForInternet: model.Ptr(internet != 0),
			InDefaultFolder:    model.Ptr(inDefault != 0),
			AltFolder:          model.Ptr(altFolder),
			Compress:           model.Ptr(compress != 0),
			PreScript:          model.Ptr(preScript),
			PostScript:         model.Ptr(postScript),
		}
		if internet != 0 {
			p.Snapshot.FTP = &model.FTP{
				Address:      model.Ptr(ftpAddress),
				Port:         model.Ptr(ftpPort),
				Subdirectory: model.Ptr(ftpSubdirectory),
				Login:        model.Ptr(ftpLogin),
				PasswordSecret: model.Ptr(e.secret(model.Join(model.Join(model.Join(publicationPath(p.Name), "snapshot"), "ftp"), "password_secret"),
					"FTP", ftpAddress, ftpLogin)),
			}
		}

		if syncTran != 0 || queuedTran != 0 {
			e.find(model.FindingOutOfScope, publicationPath(p.Name), "publication %s: updatable subscriptions (allow_sync_tran or allow_queued_tran) are out of scope", p.Name)
		}
		if dts != 0 {
			e.find(model.FindingOutOfScope, publicationPath(p.Name), "publication %s: allow_dts is set, DTS transformations are out of scope", p.Name)
		}
		if options&(decode.PubOptionP2P|decode.PubOptionP2PLocalChangesOnly|decode.PubOptionP2PConflictDetection|decode.PubOptionLastWriterWins) != 0 {
			e.find(model.FindingOutOfScope, publicationPath(p.Name), "publication %s: peer-to-peer options are set (options = 0x%X), out of scope", p.Name, options)
		}
		if options&decode.PubOptionNonSQLSubscribers != 0 {
			e.find(model.FindingOutOfScope, publicationPath(p.Name), "publication %s: enabled for non-SQL Server subscribers, out of scope", p.Name)
		}
		if u := decode.PublicationOptionUnknownBits(options); u != 0 {
			e.find(model.FindingNote, publicationPath(p.Name), "publication %s: undecoded bits in syspublications.options: 0x%X", p.Name, u)
		}

		p.Articles = []model.Article{}
		e.pubIndex[pubid] = len(e.cfg.Publications)
		e.cfg.Publications = append(e.cfg.Publications, p)
	}
	return rows.Err()
}

func (e *exporter) readArticles() error {
	columns, err := e.readArticleColumns()
	if err != nil {
		return err
	}
	if err := e.readTableArticles(columns); err != nil {
		return err
	}
	if err := e.readSchemaArticles(); err != nil {
		return err
	}
	e.articleNames = map[int][]string{}
	for pubid, i := range e.pubIndex {
		arts := e.cfg.Publications[i].Articles
		sort.Slice(arts, func(a, b int) bool { return arts[a].Name < arts[b].Name })
		for _, a := range arts {
			e.articleNames[pubid] = append(e.articleNames[pubid], a.Name)
		}
	}
	return nil
}

func (e *exporter) readArticleColumns() (map[int][]string, error) {
	cols := map[int][]string{}
	rows, err := e.src.Publisher.QueryContext(e.ctx, qArticleColumns)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var artid int
		var name string
		if err := rows.Scan(&artid, &name); err != nil {
			return nil, err
		}
		cols[artid] = append(cols[artid], name)
	}
	return cols, rows.Err()
}

func (e *exporter) readTableArticles(columns map[int][]string) error {
	rows, err := e.src.Publisher.QueryContext(e.ctx, qTableArticles)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			pubid, artid, typ, status, preCreation, syncObjID, objID, fireTriggers, tableColumns int
			schemaOption                                                                         []byte
			insCmd, updCmd, delCmd, filterClause, filterSchema, filterName                       string
			syncSchema, syncName                                                                 string
			t                                                                                    articleText
			a                                                                                    model.Article
		)
		err := rows.Scan(&pubid, &artid, &a.Name, &typ, &status, &preCreation, &schemaOption,
			&t.description, &a.Source.Schema, &a.Source.Name,
			&t.destSchema, &t.destName,
			&insCmd, &updCmd, &delCmd,
			&filterClause, &filterSchema, &filterName,
			&syncObjID, &objID, &syncSchema, &syncName,
			&t.creationScript, &fireTriggers, &tableColumns)
		if err != nil {
			return err
		}
		p := e.publication(pubid)
		if p == nil {
			e.find(model.FindingNote, "publications", "article %s: publication id %d not found", a.Name, pubid)
			continue
		}
		if err := e.fillCommon(&a, p.Name, typ, preCreation, schemaOption, t); err != nil {
			return err
		}

		a.InsertColumnNames = model.Ptr(status&decode.ArticleStatusInsertColumnNames != 0)
		a.Parameterized = model.Ptr(status&decode.ArticleStatusParameterized != 0)
		if u := decode.ArticleStatusUnknownBits(status); u != 0 {
			e.find(model.FindingNote, articlePath(p.Name, a.Name), "article %s.%s: undecoded bits in sysarticles.status: 0x%X", p.Name, a.Name, u)
		}
		a.Commands = &model.Commands{
			Insert: command(insCmd),
			Update: command(updCmd),
			Delete: command(delCmd),
		}

		// sp_articlefilter requires @filter_name, so a filter procedure is
		// always named by the user, whatever the article type. A filter
		// clause without a procedure is kept too: sp_addarticle stores it
		// before any sp_articlefilter call. The synchronization view is
		// generated as syncobj_0x<hex> unless sp_articleview or a manual
		// view type named it. Measured on SQL Server 2022 (lab/README.md).
		if filterClause != "" || filterName != "" {
			a.Filter = &model.Filter{Clause: filterClause}
			if filterName != "" {
				a.Filter.Procedure = &model.ObjectName{Schema: filterSchema, Name: filterName}
			} else if filterClause != "" {
				// Measured (lab/campaign/04-filter-clause.sh, case F1): such a clause
				// filters the snapshot, not the log reader.
				e.find(model.FindingIncomplete, model.Join(articlePath(p.Name, a.Name), "filter"), "article %s.%s: filter clause without a filter procedure (sp_articlefilter); it filters the snapshot only, changes are replicated unfiltered", p.Name, a.Name)
			}
		}
		if syncObjID != 0 && syncObjID != objID && !strings.HasPrefix(syncName, "syncobj_0x") {
			a.SyncObject = &model.ObjectName{Schema: syncSchema, Name: syncName}
		}
		a.FireTriggersOnSnapshot = model.Ptr(fireTriggers != 0)

		// sysarticlecolumns lists the published columns; the article is
		// vertically filtered when it lists fewer columns than the table has.
		if c := columns[artid]; len(c) > 0 && len(c) < tableColumns {
			a.Columns = c
		}

		p.Articles = append(p.Articles, a)
	}
	return rows.Err()
}

func (e *exporter) readSchemaArticles() error {
	rows, err := e.src.Publisher.QueryContext(e.ctx, qSchemaArticles)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			pubid, artid, typ, preCreation int
			schemaOption                   []byte
			t                              articleText
			a                              model.Article
		)
		err := rows.Scan(&pubid, &artid, &a.Name, &typ, &preCreation, &schemaOption,
			&t.description, &a.Source.Schema, &a.Source.Name,
			&t.destSchema, &t.destName, &t.creationScript)
		if err != nil {
			return err
		}
		p := e.publication(pubid)
		if p == nil {
			e.find(model.FindingNote, "publications", "article %s: publication id %d not found", a.Name, pubid)
			continue
		}
		if err := e.fillCommon(&a, p.Name, typ, preCreation, schemaOption, t); err != nil {
			return err
		}
		p.Articles = append(p.Articles, a)
	}
	return rows.Err()
}

// articleText holds the string columns shared by sysarticles and
// sysschemaarticles, scanned before they are set as properties.
type articleText struct {
	description, destSchema, destName, creationScript string
}

func (e *exporter) fillCommon(a *model.Article, pub string, typ, preCreation int, schemaOption []byte, t articleText) error {
	a.Type = model.Ptr(decode.ArticleType(typ))
	a.Description = model.Ptr(t.description)
	a.Destination = model.Destination{Schema: model.Ptr(t.destSchema), Name: model.Ptr(t.destName)}
	a.CreationScript = model.Ptr(t.creationScript)
	a.PreCreationCmd = model.Ptr(decode.PreCreationCmd(preCreation))
	v, err := decode.SchemaOptionBytes(schemaOption)
	if err != nil {
		return fmt.Errorf("article %s.%s: %w", pub, a.Name, err)
	}
	// An empty list is written [], "no option"; nil would be "omitted".
	a.SchemaOptions = model.Ptr(append([]string{}, decode.SchemaOptionNames(v)...))
	if a.Source.Name == "" {
		e.find(model.FindingUnreadable, model.Join(articlePath(pub, a.Name), "source"), "article %s.%s: source object not found", pub, a.Name)
	}
	return nil
}

func command(s string) *model.Command {
	c := decode.ParseCommand(s)
	m := &model.Command{Mode: c.Mode}
	if c.Procedure != "" {
		m.Procedure = &model.ObjectName{Schema: c.Schema, Name: c.Procedure}
	}
	return m
}

type subscriptionKey struct {
	pubid      int
	subscriber string
	database   string
}

type subscriptionRows struct {
	articles         []string
	subscriptionType int
	syncType, nosync int
	updateMode       int
	loopback         bool
	inconsistent     bool
}

func (e *exporter) readSubscriptions() error {
	rows, err := e.src.Publisher.QueryContext(e.ctx, qSubscriptions)
	if err != nil {
		return err
	}
	defer rows.Close()

	var order []subscriptionKey
	subs := map[subscriptionKey]*subscriptionRows{}
	for rows.Next() {
		var k subscriptionKey
		var article string
		var subType, syncType, nosync, updateMode, loopback int
		if err := rows.Scan(&k.pubid, &article, &k.subscriber, &k.database,
			&subType, &syncType, &nosync, &updateMode, &loopback); err != nil {
			return err
		}
		s, ok := subs[k]
		if !ok {
			s = &subscriptionRows{subscriptionType: subType, syncType: syncType, nosync: nosync,
				updateMode: updateMode, loopback: loopback != 0}
			subs[k] = s
			order = append(order, k)
		} else if s.subscriptionType != subType || s.syncType != syncType || s.nosync != nosync ||
			s.updateMode != updateMode || s.loopback != (loopback != 0) {
			s.inconsistent = true
		}
		s.articles = append(s.articles, article)
	}
	if err := rows.Err(); err != nil {
		return err
	}

	for _, k := range order {
		s := subs[k]
		p := e.publication(k.pubid)
		if p == nil {
			continue
		}
		label := fmt.Sprintf("publication %s, subscription %s.%s", p.Name, k.subscriber, k.database)
		if s.subscriptionType != 0 {
			e.find(model.FindingOutOfScope, subscriptionPath(p.Name, k.subscriber, k.database), "%s: pull subscription, out of scope, not exported", label)
			continue
		}
		if s.updateMode != 0 {
			e.find(model.FindingOutOfScope, subscriptionPath(p.Name, k.subscriber, k.database), "%s: update_mode %d, updatable subscriptions are out of scope", label, s.updateMode)
		}
		if s.inconsistent {
			e.find(model.FindingIncomplete, subscriptionPath(p.Name, k.subscriber, k.database), "%s: articles disagree on subscription_type, sync_type, update_mode or loopback_detection; the first article's values are exported", label)
		}
		sub := model.Subscription{
			Subscriber:        k.subscriber,
			Database:          k.database,
			Type:              model.Ptr(decode.SubscriptionType(s.subscriptionType)),
			Initialization:    model.Ptr(decode.Initialization(s.syncType, s.nosync)),
			LoopbackDetection: model.Ptr(s.loopback),
		}
		sub.SubscriberType = e.subscriberType(subscriptionPath(p.Name, k.subscriber, k.database), label, k.subscriber)
		sort.Strings(s.articles)
		if !slices.Equal(s.articles, e.articleNames[k.pubid]) {
			sub.Articles = s.articles
		}
		p.Subscriptions = append(p.Subscriptions, sub)
	}
	return nil
}

// subscriberType reads the subscriber type of a subscriber at the distributor.
func (e *exporter) subscriberType(path, label, subscriber string) *string {
	var code int
	err := e.src.Distributor.QueryRowContext(e.ctx, e.distQuery(qSubscriberType),
		e.cfg.Publisher.Server, subscriber).Scan(&code)
	if err == sql.ErrNoRows {
		e.find(model.FindingIncomplete, path, "%s: subscriber %s not found in MSsubscriber_info", label, subscriber)
		return nil
	}
	if err != nil {
		e.find(model.FindingUnreadable, path, "%s: reading MSsubscriber_info: %v", label, err)
		return nil
	}
	t := decode.SubscriberType(code)
	if t != "sql_server" {
		e.find(model.FindingOutOfScope, path, "%s: subscriber type %s is out of scope", label, t)
	}
	return model.Ptr(t)
}
