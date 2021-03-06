tsne_plot <- function(df, df_bg, sp_names){
  sp_names <- sp_names %>% 
    to_snake_case() %>% 
    abbreviate(minlength = 10) %>%
    unname()
  
  sp <- 1
  df_pred <- df %>%
    filter(.[sp]==1) %>% 
    bind_rows(df_bg[[sp]]) %>%
    replace(is.na(.), 0)
  
  # Empiricamente um bom valor de perplexity é: P ~ N^1/2
  perp = round((nrow(df_pred) ^ (1/2)), digits=0)
  df_bg_tsne <- df_pred %>% 
    select(c(sp_names[[sp]], colnames(df))) %>% 
    unique()
  
  tsne_bg <- Rtsne(as.matrix(df_bg_tsne), perplexity = perp)
  
  esp_colors <- df_pred %>% 
    unique() %>% 
    select(sp_names[[sp]]) %>% 
    pull()
  
  qplot(
    tsne_bg$Y[,1], 
    tsne_bg$Y[,2],
    main = sp_names[[sp]],
    geom = "point", 
    colour = esp_colors
  )
}

fit_data <- function(df_pa, df_var, df_bg){
  fitted_data <- list()
  for (sp in colnames(df_pa)){
    predict_data <- sdmData(
      sp %>% 
        paste0(collapse = " + ") %>% 
        paste(".", sep=" ~ ") %>% 
        as.formula(), 
      train = df_pa %>% 
        select(all_of(sp)) %>% 
        bind_cols(df_var) %>% 
        filter(.[sp]==1),
      bg = df_bg[[sp]] %>% 
        bind_cols(rep(0,nrow(df_bg[[sp]])) %>% list() %>% set_names(sp))
    )
    fitted_data <- fitted_data %>% 
      append(list(predict_data) %>% set_names(sp))
  }
  return(fitted_data)
}

train_models <- function(df_pa, fitted_data, pred_methods, n_exec, n_folds){
  trained_models <- list()
  for (sp in colnames(df_pa)){
    suppressWarnings(
      a_model <-
        sdm(
          data = fitted_data[[sp]],
          methods = pred_methods,
          n = n_exec,
          cv.folds = n_folds,
          replication = "cv",
          modelSettings = list(
            svm = list(
              type = 'nu-svr',
              kernel = 'rbfdot',
              epsilon = 0.1,
              prob.model = FALSE,
              tol = 0.001,
              shrinking = TRUE
            )
          )
        )
    )
    trained_models <- trained_models %>% 
      append(list(a_model) %>% set_names(sp))
  }
  return(trained_models)
}

train_models_to_folder <- function(df_pa, fitted_data, pred_methods, n_exec, n_folds, output_folder){
  for (sp in colnames(df_pa)){
    output_folder_tmp <- output_folder %>%
      path(sp)
    if (!dir_exists(output_folder_tmp)){
      dir_create(output_folder_tmp)
    
      suppressWarnings(
        a_model <-
          sdm(
            data = fitted_data[[sp]],
            methods = pred_methods,
            n = n_exec,
            cv.folds = n_folds,
            replication = "cv",
            modelSettings = list(
              svm = list(
                type = 'nu-svr',
                kernel = 'rbfdot',
                epsilon = 0.1,
                prob.model = FALSE,
                tol = 0.001,
                shrinking = TRUE
              )
            )
          )
      )
      a_model %>% 
        saveRDS(output_folder_tmp %>% path(paste0(sp, ".sdm")))
    }
  }
}

sp_thresh <- function(t_models, thr_criteria){
  t_models %>% 
    map_dfr(~ getEvaluation(
      ., 
      stat=c(
        'threshold', 'AUC', 'COR', 'sensitivity', 'specificity', 'TSS', 'Kappa'
      ), 
      opt=thr_criteria
    ), 
    .id = "especie"
    )
}

sp_thresh_from_folder <- function(sp_name, folder, thr_criteria){
  if (length(sp_name)>1) {
    sp_name <- sp_name[1]
  }
  sp_name %>%
    sp_model_from_folder(folder) %>%
    sp_thresh(thr_criteria) %>%
    mutate(especie_name=sp_name)
}

thresh_mean <- function(t_models, df_thr){ #, pred_methods){
  t_models %>% 
    map_dfr(~ (getModelInfo(.) %>% mutate_if(is.factor, as.character)), .id="especie") %>% 
    #filter(method %in% pred_methods) %>%
    select(especie, modelID, method) %>%
    inner_join(df_thr %>% select(especie, modelID, threshold), by=c("especie", "modelID")) %>%
    group_by(especie, method) %>% 
    summarize(mean = mean(threshold), .groups = 'rowwise') %>%
    return()
}

sp_thresh_mean_from_folder <- function(sp_name, folder, df_thr){
  if (length(sp_name)>1) {
    sp_name <- sp_name[1]
  }
  sp_name %>%
    sp_model_from_folder(folder) %>%
    thresh_mean(df_thr)
} 

sp_model_from_folder <- function(sp_name, folder){
  sp_name <- sp_name %>% 
    to_snake_case() %>% 
    abbreviate(minlength = 10) %>% 
    unname()

  folder %>% 
    #dir_ls(glob = paste0("*", sp_name, "*.sdm"), recurse = T) %>%
    dir_ls(glob = paste0("*", sp_name, ".sdm"), recurse = T) %>%
    readRDS() %>%
    list() %>%
    set_names(sp_name)
}

sp_predictions_from_folder <- function(sp_name, folder){
  sp_name <- sp_name %>% 
    to_snake_case() %>% 
    abbreviate(minlength = 10) %>% 
    unname()

  suppressMessages(
    folder %>% 
      dir_ls(glob = paste0("*", sp_name, "*.csv"), recurse = T) %>% 
      purrr::map(vroom) %>% 
      set_names(path_file) %>% 
      set_names(path_ext_remove)
  )
}

predict_sp_to_folder <- function(df_pa, df_var, t_models, shp, pred_methods, thr_criteria, output_folder){
    if (dir_exists(output_folder))
    dir_delete(output_folder)
  
  dir_create(output_folder)
  
  for (sp in colnames(df_pa)){
    df_pred_freq <- df_var %>% 
      DRE_predict(t_models[[sp]], pred_methods, thr_criteria)
    # <- DRE_predict(modelos_treinados, df_predicao_var, alg_predicao, criterio_thres, thresholds_modelos_mcc)
    
    colnames(df_pred_freq) <- pred_methods
    df_pred_freq <- df_pred_freq %>% 
      mutate(consenso=rowMeans(.))
    
    # Consenso usando presenca/ausencia
    df_pred_pres_aus <- df_pred_freq %>%
      select(-consenso) %>%
      mutate_all(~ ifelse(. <= 0.5, 0, 1)) %>%
      mutate(consenso = rowMeans(.) %>% round(., digits = 0))
    
    df_pred_freq <- df_pa %>% 
      select(sp %>% all_of()) %>% 
      cbind(df_pred_freq)
    
    df_pred_pres_aus <- df_pa %>% 
      select(sp %>% all_of()) %>%
      cbind(df_pred_pres_aus)
    
    shp_tmp <- shp
    
    shp_tmp@data <- df_pred_freq 
    shp_tmp %>%
      writeOGR(
        dsn = output_folder %>% fs::path(sp), 
        layer=paste0(sp, "_freq"), 
        driver="ESRI Shapefile"
      )
    
    shp_tmp@data <- df_pred_pres_aus
    shp_tmp %>% 
      writeOGR(
        dsn = output_folder %>% fs::path(sp), 
        layer=paste0(sp, "_pa"), 
        driver="ESRI Shapefile"
      )
  }
}

# TODO: Qual o comportamento da predição para a pasta, sobreescrever sempre ou continuar de onde parou? Qual o comportamento para as outras funções sobreescrever ou continuar?
predict_to_folder <- function(df_pa, scenarios_list, models_folder, shp_grid, pred_methods, thr_criteria, output_folder){
  for (sp in colnames(df_pa)){
    t_models <- sp %>%
      sp_model_from_folder(models_folder)
    if (scenarios_list %>% is.data.frame()){
      scenarios_list <- scenarios_list %>%
        list() %>%
        set_names("cenário")
    }

    for (scenario_name in names(scenarios_list)){
      folder_tmp <- output_folder %>% path("predicao_sp") %>% path(sp) %>% path(scenario_name)
      file_tmp <- scenario_name

      if (!dir_exists(folder_tmp)){
        df_pred_freq <- scenarios_list %>% 
          pluck(scenario_name) %>% 
          DRE_predict(t_models %>% pluck(sp), pred_methods, thr_criteria)
  
        df_pred_freq <- df_pred_freq %>% 
          mutate(consenso=rowMeans(.))
        
        # Consenso usando presenca/ausencia
        df_pred_pres_aus <- df_pred_freq %>%
          select(-consenso) %>%
          mutate_all(~ ifelse(. <= 0.5, 0, 1)) %>%
          mutate(consenso = rowMeans(.) %>% round(., digits = 0))

        df_pred_freq <- rep(sp, nrow(df_pred_freq)) %>% 
          as.data.frame() %>% 
          rename("especie"=".") %>%
          bind_cols(rep(scenario_name, nrow(df_pred_freq)) %>% as.data.frame()) %>%
          rename("cenario"=".") %>%
          bind_cols(df_pred_freq)
          
        df_pred_pres_aus <- rep(sp, nrow(df_pred_pres_aus)) %>% 
          as.data.frame() %>% 
          rename("especie"=".") %>%
          bind_cols(rep(scenario_name, nrow(df_pred_pres_aus)) %>% as.data.frame()) %>%
          rename("cenario"=".") %>%
          bind_cols(df_pred_pres_aus)
      
          
        folder_tmp %>% 
          dir_create(recurse = T)
        
        colnames(df_pred_freq) <- df_pred_freq %>% 
          colnames() %>%
          to_snake_case() %>%
          abbreviate(minlength = 10) %>%
          unname()
        
        suppressMessages(
          df_pred_freq %>%
            vroom_write(
              folder_tmp %>% 
                path(file_tmp) %>% 
                paste0("_freq.csv"),
              delim = ";"
            )
        )
        
        colnames(df_pred_pres_aus) <- df_pred_freq %>% 
          colnames() %>%
          to_snake_case() %>%
          abbreviate(minlength = 10) %>%
          unname()
        
        suppressMessages(
          df_pred_pres_aus %>%
            vroom_write(
              folder_tmp %>% 
                path(file_tmp) %>% 
                paste0("_pa.csv"),
              delim = ";"  
            )
        )
      }
    }
  }
}


model_failures <- function(fitted_data, models_folder){
  fitted_data %>% 
    names() %>% 
    map_dfr(~ 
              sp_model_from_folder(., models_folder) %>%
              pluck(1) %>%
              slot("run.info") %>% 
              select(species, method, success) %>%
              filter(success == F) %>%
              unique()
    )
}

# TODO: Esse método precisa ser refatorado: quebrado em diversos outros métodos. Também precisa ser melhorado com novas funções.
gerarPseudoAusenciasDRE <- function (shp_pa, df_var, especies, metodo="random", cluster_m="k-means"){
  especies <- especies %>% 
    to_snake_case() %>% 
    abbreviate(minlength = 10) %>%
    unname()
  
  df_pa <- shp_pa@data %>% select(all_of(especies))
  .add_grupos <- function(a_df, a_df_p, percent_grupos=NA, nro_grupos=NA, cluster_m="k-means"){
    if (cluster_m=="k-means"){
      if (is.na(nro_grupos)) {
        nro_grupos <- round(nrow(a_df_p)/percent_grupos)  
      }
      set.seed(nro_grupos)
      a_df$grupo <- a_df %>% 
        select(-any_of("grupo")) %>%
        kmeans(nro_grupos) %>%
        pluck("cluster") %>%
        as.factor()
    }
    else {
      # Não está funcionando
      if (is.na(nro_grupos)){
        nro_grupos <- ceiling(nrow(a_df_p)/percent_grupos)  
      } 
      a_df$grupo <- a_df %>% 
        as.matrix() %>% 
        Xmeans(nrow(a_df)/100, nthread = 3, min.clust.size = nro_grupos) %>%
        pluck("cluster")
    }
    return(a_df)
  }
  
  .get_summary_from <- function(a_df_var, a_list_pa){
    p <- a_list_pa %>% keep(~ .==1)
    grupos <- a_df_var %>% 
      bind_cols(especie=a_list_pa) %>%
      group_by(grupo) %>%
      summarise(
        presencas = sum(especie), 
        quant_celulas= n(), 
        dens_presenca=sum(especie)/n(), 
        presenca_rel=sum(especie)/nrow(a_df_var),
        quant_cel_bg= round(n() * length(p) / nrow(a_df_var)) 
      ) #%>%
    #filter(dens_presenca <= mean(.$dens_presenca))
    return(grupos)
  }
  
  if (metodo == "cluster") {
    backgrounds = list()
    for (sp in colnames(df_pa)){
      df_p <- df_pa %>% select(sp %>% all_of()) %>% filter(.[sp]==1)
      df_var <- df_var %>% .add_grupos(df_p, percent_grupos = 10, cluster_m = cluster_m) # k = 10% do numero de pres.
      grupos <- df_var %>% .get_summary_from(df_pa[[sp]])
      
      df_bg <- df_var %>%
        bind_cols(especie=df_pa[[sp]]) %>%
        filter(especie==0) %>%
        filter(grupo %in% grupos$grupo) %>%
        group_by(grupo) %>% 
        select(-especie) %>%
        nest() %>%
        ungroup() %>%
        mutate(n=grupos$quant_cel_bg) 
      
      df_bg_tmp <- try(
        df_bg %>% 
          mutate(samp = map2(data, n, sample_n)) %>% 
          select(-data, -n, -grupo) %>%
          unnest(samp)
      )
      if ("try-error" %in% class(df_bg_tmp)){
        df_bg <- df_bg %>% 
          mutate(samp = map2(data, n, ~ sample_n(.x, .y, replace = T))) %>% 
          select(-data, -n, -grupo) %>%
          unnest(samp)
      }
      else {
        df_bg <- df_bg_tmp
      }
      
      backgrounds <- backgrounds %>% 
        append(list(df_bg) %>% set_names(sp))
    }
    return(backgrounds)
    # # visualização dos pontos de background
    # grid_temp <- grid
    # grid_temp@data <- df_tmp
    # grid_temp@data$id <- rownames(grid_temp@data)
    # grid_temp <- fortify(grid_temp, region = "id") %>% left_join(grid_temp@data)
    # 
    # ggplot(data = fortify(grid_temp)) +
    #   aes(x = long,
    #       y = lat,
    #       group = group,
    #       text = grupo) +
    #   geom_polygon(aes(fill = as.factor(grupo))) +
    #   #geom_point(
    #   #  data = df_bg %>% filter(species == 1),
    #   #  aes(x = long, y = lat, colour = species),
    #   #  size = 0.5
    #   #) +
    #   theme(
    #     axis.text.x = element_blank(),
    #     axis.text.y = element_blank(),
    #     axis.ticks.x = element_blank(),
    #     axis.ticks.y = element_blank()
    #   ) +
    #   coord_equal()
    
  } else if (metodo=="dre_area" || metodo=="dre_dens"){
    quant_max <- 0
    num_grupo_quant_max <- 2
    dens_acum <- 0
    num_grupo_dens_acum <- 2
    backgrounds = list()
    for (sp in colnames(df_pa)){
      df_p <- df_pa %>% select(sp %>% all_of()) %>% filter(.[sp]==1)
      
      numero_grupos <- trunc(nrow(df_p))
      for (i in 2:numero_grupos){
        df_var <- df_var %>% .add_grupos(df_p, nro_grupos=i) # k = 1 do numero de pres.
        grupos <- df_var %>% .get_summary_from(df_pa[[sp]])
        
        grupos_area <- grupos %>%
          filter(dens_presenca <=mean(grupos$dens_presenca))
        
        grupos_dens <- grupos %>%
          filter(dens_presenca > mean(grupos$dens_presenca))
        
        if (sum(grupos_area$quant_celulas) > quant_max){
          quant_max <- sum(grupos_area$quant_celulas)
          num_grupo_quant_max <- i
        }
        if (sum(grupos_dens$presencas) / sum(grupos_dens$quant_celulas) > dens_acum){
          dens_acum <- sum(grupos_dens$presencas) / sum(grupos_dens$quant_celulas)
          num_grupo_dens_acum <- i
        }
      }
      
      if (metodo=="dre_area"){
        numero_grupos <- num_grupo_quant_max  
      } else {
        numero_grupos <- num_grupo_dens_acum
      }
      
      df_var <- df_var %>% .add_grupos(df_p, nro_grupos=numero_grupos) # k = 1 do numero de pres.
      grupos <- df_var %>% .get_summary_from(df_pa[[sp]])
      
      if (metodo=="dre_area"){
        grupos <- grupos %>%
          filter(dens_presenca <=mean(grupos$dens_presenca))
      }
      else {
        grupos <- grupos %>%
          filter(dens_presenca > mean(grupos$dens_presenca))
      }
      grupos <- grupos %>% 
        mutate(quant_cel_bg=round(nrow(df_p) * grupos$quant_celulas / sum(grupos$quant_celulas)))
      
      
      df_bg <- df_var %>%
        bind_cols(especie=df_pa[[sp]]) %>%
        filter(especie==0) %>%
        filter(grupo %in% grupos$grupo) %>%
        group_by(grupo) %>% 
        select(-especie) %>%
        nest() %>%
        ungroup() %>%
        arrange(grupo) %>%
        mutate(n=grupos$quant_cel_bg)
      
      df_bg_tmp <- try(
        df_bg %>% 
          mutate(samp = map2(data, n, sample_n)) %>% 
          select(-data, -n, -grupo) %>%
          unnest(samp)
      )
      
      if ("try-error" %in% class(df_bg_tmp)){
        df_bg <- df_bg %>% 
          mutate(samp = map2(data, n, ~ sample_n(.x, .y, replace = T))) %>% 
          select(-data, -n, -grupo) %>%
          unnest(samp)
      }
      else {
        df_bg <- df_bg_tmp
      }
      
      backgrounds <- backgrounds %>% 
        append(list(df_bg) %>% set_names(sp))
    }
    return(backgrounds)
  } 
  else {
    backgrounds = list()
    for (sp in colnames(df_pa)){
      df_p <- df_pa %>% select(sp %>% all_of()) %>% filter(.[sp]==1)
      
      df_bg <- df_var %>%
        bind_cols(especie=df_pa[[sp]]) %>%
        filter(especie==0) %>%
        sample_n(nrow(df_p)) %>%
        select(-especie)
      
      backgrounds <- backgrounds %>% 
        append(list(df_bg) %>% set_names(sp))
    }
    return(backgrounds)
  }
}
