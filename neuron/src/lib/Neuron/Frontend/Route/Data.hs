{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Neuron.Frontend.Route.Data where

import qualified Data.Dependent.Map as DMap
import Data.Foldable (Foldable (maximum))
import qualified Data.Set as Set
import Data.TagTree (mkDefaultTagQuery, mkTagPattern)
import Data.Tree (Forest, Tree (..))
import Neuron.Cache.Type (NeuronCache (..))
import qualified Neuron.Config.Type as Config
import Neuron.Frontend.Manifest (Manifest)
import Neuron.Frontend.Route.Data.Types
import qualified Neuron.Frontend.Theme as Theme
import qualified Neuron.Plugin as Plugin
import Neuron.Zettelkasten.Connection (Connection (Folgezettel))
import qualified Neuron.Zettelkasten.Graph as G
import Neuron.Zettelkasten.ID (indexZid)
import Neuron.Zettelkasten.Query (zettelsByTag)
import Neuron.Zettelkasten.Query.Eval
  ( buildQueryUrlCache,
  )
import Neuron.Zettelkasten.Zettel
import Relude hiding (traceShowId)
import qualified Text.Pandoc.Util as P

mkZettelData :: NeuronCache -> ZettelC -> ZettelData
mkZettelData NeuronCache {..} zC = do
  let z = sansContent zC
      upTree = G.backlinkForest Folgezettel z _neuronCache_graph
      backlinks = G.backlinks isJust z _neuronCache_graph
      -- All URLs we expect to see in the final HTML.
      allUrls =
        Set.toList . Set.fromList $
          -- Gather urls from zettel content, and ...
          either (const []) (P.getLinks . zettelContent) zC
            -- Gather urls from backlinks context.
            <> concat (P.getLinks . snd . fst <$> backlinks)
      qurlcache = buildQueryUrlCache (G.getZettels _neuronCache_graph) allUrls
      pluginData =
        DMap.fromList $
          Plugin.routePluginData _neuronCache_graph <$> DMap.toList (zettelPluginData z)
  ZettelData zC qurlcache upTree backlinks pluginData

mkImpulseData :: NeuronCache -> ImpulseData
mkImpulseData NeuronCache {..} =
  buildImpulse _neuronCache_graph _neuronCache_errors
  where
    buildImpulse graph errors =
      let (orphans, clusters) = partitionEithers $
            flip fmap (G.categoryClusters graph) $ \case
              [Node z []] -> Left z -- Orphans (cluster of exactly one)
              x -> Right x
          clustersWithUplinks :: [Forest (Zettel, [Zettel])] =
            -- Compute backlinks for each node in the tree.
            flip fmap clusters $ \(zs :: [Tree Zettel]) ->
              G.backlinksMulti Folgezettel zs graph
          stats = Stats (length $ G.getZettels graph) (G.connectionCount graph)
          pinnedZettels = zettelsByTag (G.getZettels graph) $ mkDefaultTagQuery [mkTagPattern "pinned"]
       in ImpulseData (fmap sortCluster clustersWithUplinks) orphans errors stats pinnedZettels
    -- TODO: Either optimize or get rid of this (or normalize the sorting somehow)
    sortCluster fs =
      sortZettelForest $
        flip fmap fs $ \Node {..} ->
          Node rootLabel $ sortZettelForest subForest
    -- Sort zettel trees so that trees containing the most recent zettel (by ID) come first.
    sortZettelForest = sortOn (Down . maximum)

mkSiteData :: NeuronCache -> HeadHtml -> Manifest -> SiteData
mkSiteData NeuronCache {..} headHtml manifest =
  let theme = Theme.mkTheme $ Config.theme _neuronCache_config
      siteTitle = Config.siteTitle _neuronCache_config
      siteAuthor = Config.author _neuronCache_config
      baseUrl = join $ Config.getSiteBaseUrl _neuronCache_config
      indexZettel = G.getZettel indexZid _neuronCache_graph
      editUrl = Config.editUrl _neuronCache_config
   in SiteData theme siteTitle siteAuthor baseUrl editUrl headHtml manifest _neuronCache_neuronVersion indexZettel
