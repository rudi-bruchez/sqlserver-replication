package reader

import (
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
			p                                                                model.Publication
			ftp                                                              model.FTP
		)
		err := rows.Scan(&pubid, &p.Name, &p.Description,
			&replFreq, &status, &syncMethod, &retention,
			&independent, &immediate, &internet, &push, &pull, &anonymous,
			&syncTran, &queuedTran, &dts, &subCopy, &fromBackup, &ddl,
			&options, &inDefault,
			&p.Snapshot.AltFolder, &p.Snapshot.PreScript, &p.Snapshot.PostScript, &compress,
			&ftp.Address, &ftpPort, &ftp.Subdirectory, &ftp.Login)
		if err != nil {
			return err
		}
		p.Type = decode.PublicationType(replFreq)
		p.Status = decode.PublicationStatus(status)
		p.SyncMethod = decode.SyncMethod(syncMethod)
		p.RetentionHours = retention
		p.IndependentAgent = independent != 0
		p.ImmediateSync = immediate != 0
		p.AllowPush = push != 0
		p.AllowPull = pull != 0
		p.AllowAnonymous = anonymous != 0
		p.AllowSubscriptionCopy = subCopy != 0
		p.AllowInitializeFromBackup = fromBackup != 0
		p.ReplicateDDL = ddl != 0
		p.AllowDrop = options&decode.PubOptionAllowDrop != 0
		p.Snapshot.InDefaultFolder = inDefault != 0
		p.Snapshot.Compress = compress != 0
		if internet != 0 {
			ftp.Port = ftpPort
			ftp.PasswordSecret = "ftp/" + p.Name
			p.Snapshot.FTP = &ftp
		}

		if replFreq != 0 {
			e.warn("publication %s: snapshot publication, out of scope", p.Name)
		}
		if syncTran != 0 || queuedTran != 0 {
			e.warn("publication %s: updatable subscriptions (allow_sync_tran or allow_queued_tran) are out of scope", p.Name)
		}
		if dts != 0 {
			e.warn("publication %s: allow_dts is set, DTS transformations are out of scope", p.Name)
		}
		if options&(decode.PubOptionP2P|decode.PubOptionP2PLocalChangesOnly|decode.PubOptionP2PConflictDetection|decode.PubOptionLastWriterWins) != 0 {
			e.warn("publication %s: peer-to-peer options are set (options = 0x%X), out of scope", p.Name, options)
		}
		if options&decode.PubOptionNonSQLSubscribers != 0 {
			e.warn("publication %s: enabled for non-SQL Server subscribers, out of scope", p.Name)
		}
		if u := decode.PublicationOptionUnknownBits(options); u != 0 {
			e.warn("publication %s: undecoded bits in syspublications.options: 0x%X", p.Name, u)
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
			a                                                                                    model.Article
		)
		err := rows.Scan(&pubid, &artid, &a.Name, &typ, &status, &preCreation, &schemaOption,
			&a.Description, &a.Source.Schema, &a.Source.Name,
			&a.Destination.Schema, &a.Destination.Name,
			&insCmd, &updCmd, &delCmd,
			&filterClause, &filterSchema, &filterName,
			&syncObjID, &objID, &syncSchema, &syncName,
			&a.CreationScript, &fireTriggers, &tableColumns)
		if err != nil {
			return err
		}
		p := e.publication(pubid)
		if p == nil {
			e.warn("article %s: publication id %d not found", a.Name, pubid)
			continue
		}
		if err := e.fillCommon(&a, p.Name, typ, preCreation, schemaOption); err != nil {
			return err
		}

		a.Active = status&decode.ArticleStatusActive != 0
		a.InsertColumnNames = status&decode.ArticleStatusInsertColumnNames != 0
		a.Parameterized = status&decode.ArticleStatusParameterized != 0
		if u := decode.ArticleStatusUnknownBits(status); u != 0 {
			e.warn("article %s.%s: undecoded bits in sysarticles.status: 0x%X", p.Name, a.Name, u)
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
				e.warn("article %s.%s: filter clause without a filter procedure (sp_articlefilter); it filters the snapshot only, changes are replicated unfiltered", p.Name, a.Name)
			}
		}
		if syncObjID != 0 && syncObjID != objID && !strings.HasPrefix(syncName, "syncobj_0x") {
			a.SyncObject = &model.ObjectName{Schema: syncSchema, Name: syncName}
		}
		a.FireTriggersOnSnapshot = fireTriggers != 0

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
			a                              model.Article
		)
		err := rows.Scan(&pubid, &artid, &a.Name, &typ, &preCreation, &schemaOption,
			&a.Description, &a.Source.Schema, &a.Source.Name,
			&a.Destination.Schema, &a.Destination.Name, &a.CreationScript)
		if err != nil {
			return err
		}
		p := e.publication(pubid)
		if p == nil {
			e.warn("article %s: publication id %d not found", a.Name, pubid)
			continue
		}
		if err := e.fillCommon(&a, p.Name, typ, preCreation, schemaOption); err != nil {
			return err
		}
		p.Articles = append(p.Articles, a)
	}
	return rows.Err()
}

func (e *exporter) fillCommon(a *model.Article, pub string, typ, preCreation int, schemaOption []byte) error {
	a.Type = decode.ArticleType(typ)
	a.PreCreationCmd = decode.PreCreationCmd(preCreation)
	v, err := decode.SchemaOptionBytes(schemaOption)
	if err != nil {
		return fmt.Errorf("article %s.%s: %w", pub, a.Name, err)
	}
	a.SchemaOptions = decode.SchemaOptionNames(v)
	if a.Source.Name == "" {
		e.warn("article %s.%s: source object not found", pub, a.Name)
	}
	return nil
}

func command(s string) model.Command {
	c := decode.ParseCommand(s)
	m := model.Command{Mode: c.Mode}
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
			e.warn("%s: pull subscription, out of scope, not exported", label)
			continue
		}
		if s.updateMode != 0 {
			e.warn("%s: update_mode %d, updatable subscriptions are out of scope", label, s.updateMode)
		}
		if s.inconsistent {
			e.warn("%s: articles disagree on subscription_type, sync_type, update_mode or loopback_detection; the first article's values are exported", label)
		}
		sub := model.Subscription{
			Subscriber:        k.subscriber,
			Database:          k.database,
			Initialization:    decode.Initialization(s.syncType, s.nosync),
			LoopbackDetection: s.loopback,
		}
		sort.Strings(s.articles)
		if !slices.Equal(s.articles, e.articleNames[k.pubid]) {
			sub.Articles = s.articles
		}
		p.Subscriptions = append(p.Subscriptions, sub)
	}
	return nil
}
